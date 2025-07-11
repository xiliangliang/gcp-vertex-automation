#!/bin/bash
# 文件名：gemini_key_manager.sh (全功能最终版)
# 功能：一个多功能的Gemini API密钥管理工具。
#       1. 批量创建新项目并生成密钥 (混合模式)。
#       2. 检查所有已启用结算的项目，提取或创建密钥。

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ======== 辅助函数 ========

function error_exit() {
  echo -e "\n${RED}❌ 错误: $1${RESET}\n"
  exit 1
}

function press_any_key_to_continue() {
  echo ""
  read -n 1 -s -r -p "按任意键返回主菜单..."
}

function check_dependencies() {
  echo -e "${YELLOW}正在检查依赖工具...${RESET}"
  for tool in gcloud jq column; do
    if ! command -v "$tool" &> /dev/null; then
      error_exit "${tool} CLI 未安装。请先安装它。"
    fi
  done
  
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '@'; then
    echo -e "${YELLOW}您尚未登录 gcloud。正在引导您登录...${RESET}"
    gcloud auth login --quiet || error_exit "gcloud 登录失败。"
    gcloud auth application-default login --quiet || error_exit "gcloud 应用默认凭证设置失败。"
  fi
  echo -e "${GREEN}✓ 依赖和登录状态正常。${RESET}"
}

# ======== 功能模块 1: 创建新项目 ========

function hybrid_batch_creator_flow() {
  echo -e "\n${YELLOW}=== 功能: 批量创建新项目和密钥 ===${RESET}"
  
  read -p "您想创建多少个新项目? " PROJECT_COUNT
  if ! [[ "$PROJECT_COUNT" =~ ^[1-9][0-9]*$ ]]; then echo -e "${RED}请输入一个大于0的有效数字。${RESET}"; return; fi
  
  declare -a NEW_PROJECT_IDS
  BASE_PROJECT_NAME="gemini-hybrid-$(date +%Y%m%d)"
  
  echo -e "\n${YELLOW}1. 正在批量创建 ${PROJECT_COUNT} 个项目...${RESET}"
  for i in $(seq 1 "$PROJECT_COUNT"); do
    PROJECT_ID="${BASE_PROJECT_NAME}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    echo -e "  -> 正在创建项目 [${i}/${PROJECT_COUNT}]: ${BLUE}${PROJECT_ID}${RESET}..."
    if gcloud projects create "$PROJECT_ID" --quiet; then
      echo -e "  ${GREEN}✓ 创建成功。${RESET}"; NEW_PROJECT_IDS+=("$PROJECT_ID")
    else
      echo -e "  ${RED}✗ 创建失败，已跳过。${RESET}"
    fi
  done
  
  if [ ${#NEW_PROJECT_IDS[@]} -eq 0 ]; then echo -e "${RED}没有成功创建任何项目，操作终止。${RESET}"; return; fi
  
  echo -e "\n\n${YELLOW}====================【请您现在操作】====================${RESET}"
  echo -e "${YELLOW}2. 项目已创建，现在需要您手动为它们关联结算账户。${RESET}"
  for PROJECT_ID in "${NEW_PROJECT_IDS[@]}"; do
    echo -e "  项目: ${BLUE}${PROJECT_ID}${RESET} -> 链接: ${GREEN}https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}${RESET}\n"
  done
  echo -e "${RED}请确保为上面所有的项目都完成结算关联！${RESET}"
  echo -e "${YELLOW}==========================================================${RESET}"
  
  read -p "当您为所有项目都关联好结算账户后，请按【回车键】继续..."
  
  echo -e "\n${YELLOW}3. 正在为所有项目启用API并生成密钥...${RESET}"
  FINAL_SUMMARY="项目ID,API密钥\n"
  
  for PROJECT_ID in "${NEW_PROJECT_IDS[@]}"; do
    echo -e "\n--- 正在处理项目: ${BLUE}${PROJECT_ID}${RESET} ---"
    if [[ "$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)")" != "True" ]]; then
      echo -e "  ${RED}✗ 结算未关联，跳过。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},结算未关联\n"; continue
    fi
    echo "  正在启用API并生成密钥..."
    if ! gcloud services enable generativelanguage.googleapis.com --project="$PROJECT_ID" --quiet; then
      echo -e "  ${RED}✗ 启用API失败。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},API启用失败\n"; continue
    fi
    API_KEY=$(gcloud beta services api-keys create --display-name="Hybrid_Batch_Key_$(date +%s)" --project="$PROJECT_ID" --api-target=service=generativelanguage.googleapis.com --format="value(keyString)")
    if [[ "$API_KEY" == AIzaSy* ]]; then
      echo -e "  ${GREEN}✓ 密钥生成成功！${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},${API_KEY}\n"
    else
      echo -e "  ${RED}✗ 密钥生成失败。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},密钥生成失败\n"
    fi
  done
  
  echo -e "\n\n${GREEN}✅ 创建任务完成！摘要如下：${RESET}"
  echo "====================================================================================="
  echo -e "${FINAL_SUMMARY}" | column -t -s ','
  echo "====================================================================================="
}

# ======== 功能模块 2: 处理现有项目 ========

function process_existing_projects_flow() {
  echo -e "\n${YELLOW}=== 功能: 检查/创建现有项目的密钥 ===${RESET}"
  echo -e "${YELLOW}正在扫描您所有的项目以查找已启用结算的... (如果项目多，可能需要一些时间)${RESET}"

  ALL_PROJECTS=$(gcloud projects list --format="value(projectId)")
  if [ -z "$ALL_PROJECTS" ]; then echo -e "${RED}未找到任何项目。${RESET}"; return; fi

  FINAL_SUMMARY="项目ID,API密钥状态\n"
  
  for PROJECT_ID in $ALL_PROJECTS; do
    echo -ne "\r${YELLOW}  -> 正在检查项目: ${BLUE}${PROJECT_ID}${RESET}                    "
    if [[ "$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null)" != "True" ]]; then
      continue # 跳过未启用结算的项目
    fi
    
    echo -e "\r${GREEN}  ✓ 发现已启用结算的项目: ${BLUE}${PROJECT_ID}${RESET}"
    
    # 检查是否已有Gemini密钥
    echo "    (1/2) 正在检查现有密钥..."
    EXISTING_KEY=$(gcloud beta services api-keys list --project="$PROJECT_ID" --format=json | jq -r '.[] | select(.restrictions.apiTargets[].service == "generativelanguage.googleapis.com") | .keyString' | head -n 1)

    if [ -n "$EXISTING_KEY" ]; then
      echo -e "    ${GREEN}✓ 已找到现有密钥。${RESET}"
      FINAL_SUMMARY+="${PROJECT_ID},${EXISTING_KEY}\n"
    else
      echo "    (2/2) 未找到现有密钥，正在创建新的..."
      if ! gcloud services enable generativelanguage.googleapis.com --project="$PROJECT_ID" --quiet; then
        echo -e "    ${RED}✗ 启用API失败，跳过。${RESET}"
        FINAL_SUMMARY+="${PROJECT_ID},API启用失败\n"
        continue
      fi
      NEW_KEY=$(gcloud beta services api-keys create --display-name="Managed_Gemini_Key_$(date +%s)" --project="$PROJECT_ID" --api-target=service=generativelanguage.googleapis.com --format="value(keyString)")
      if [[ "$NEW_KEY" == AIzaSy* ]]; then
        echo -e "    ${GREEN}✓ 新密钥创建成功！${RESET}"
        FINAL_SUMMARY+="${PROJECT_ID},${NEW_KEY} (新创建)\n"
      else
        echo -e "    ${RED}✗ 新密钥创建失败。${RESET}"
        FINAL_SUMMARY+="${PROJECT_ID},密钥创建失败\n"
      fi
    fi
  done

  echo -e "\n\n${GREEN}✅ 所有项目处理完毕！报告如下：${RESET}"
  echo "========================================================================================================"
  echo -e "${FINAL_SUMMARY}" | column -t -s ','
  echo "========================================================================================================"
}

# ======== 主菜单和主函数 ========

function main_menu() {
  clear
  echo -e "${YELLOW}========== Gemini API 密钥管理器 (全功能版) ==========${RESET}"
  echo -e "${GREEN}请选择您要执行的操作:${RESET}"
  echo "--------------------------------------------------------"
  echo -e "  ${BLUE}1.${RESET} 批量创建新项目并生成密钥"
  echo -e "  ${BLUE}2.${RESET} 检查/创建所有现有项目的密钥 (已启用结算的)"
  echo "--------------------------------------------------------"
  echo -e "  ${RED}3.${RESET} 退出"
  echo "========================================================"
  read -p "请输入选项 [1-3]: " CHOICE
  
  case $CHOICE in
    1) hybrid_batch_creator_flow; press_any_key_to_continue ;;
    2) process_existing_projects_flow; press_any_key_to_continue ;;
    3) echo -e "\n${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
    *) echo -e "\n${RED}无效的输入，请输入 1 到 3 之间的数字。${RESET}"; sleep 2 ;;
  esac
}

function main() {
  check_dependencies
  while true; do
    main_menu
  done
}

main
