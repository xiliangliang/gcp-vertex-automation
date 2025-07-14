#!/bin/bash
# 文件名：hybrid_batch_creator.sh (混合模式最终版)
# 功能：批量创建项目，引导用户手动关联结算，然后自动完成API启用和密钥生成。
#       此版本旨在绕过因账户类型限制而无法通过API关联结算的问题。
# 手动关联结算项目版，目前使用版，关联5个结算项目

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

function check_dependencies() {
  echo -e "${YELLOW}1. 正在检查依赖工具...${RESET}"
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

# ======== 主函数 ========

function main() {
  echo -e "${YELLOW}=== Gemini API密钥批量生成器 (混合模式) ===${RESET}"
  
  check_dependencies
  
  # --- 第1部分：批量创建项目 ---
  echo ""
  read -p "您想创建多少个新项目? " PROJECT_COUNT
  if ! [[ "$PROJECT_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    error_exit "请输入一个大于0的有效数字。"
  fi
  
  # 用于存储新创建的项目ID
  declare -a NEW_PROJECT_IDS
  BASE_PROJECT_NAME="gemini-hybrid-$(date +%Y%m%d)"
  
  echo -e "\n${YELLOW}2. 正在批量创建 ${PROJECT_COUNT} 个项目...${RESET}"
  for i in $(seq 1 "$PROJECT_COUNT"); do
    PROJECT_ID="${BASE_PROJECT_NAME}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    echo -e "  -> 正在创建项目 [${i}/${PROJECT_COUNT}]: ${BLUE}${PROJECT_ID}${RESET}..."
    
    if gcloud projects create "$PROJECT_ID" --quiet; then
      echo -e "  ${GREEN}✓ 创建成功。${RESET}"
      NEW_PROJECT_IDS+=("$PROJECT_ID")
    else
      echo -e "  ${RED}✗ 创建失败，已跳过。${RESET}"
    fi
  done
  
  if [ ${#NEW_PROJECT_IDS[@]} -eq 0 ]; then
    error_exit "没有成功创建任何项目，脚本终止。"
  fi
  
  # --- 第2部分：引导用户手动关联结算 ---
  echo -e "\n\n${YELLOW}====================【请您现在操作】====================${RESET}"
  echo -e "${YELLOW}3. 项目已创建，现在需要您手动为它们关联结算账户。${RESET}"
  echo "请为下面列出的每一个项目完成结算关联："
  echo "----------------------------------------------------------------"
  for PROJECT_ID in "${NEW_PROJECT_IDS[@]}"; do
    BILLING_URL="https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}"
    echo -e "  项目: ${BLUE}${PROJECT_ID}${RESET}"
    echo -e "  请点击链接: ${GREEN}${BILLING_URL}${RESET}\n"
  done
  echo "----------------------------------------------------------------"
  echo -e "${YELLOW}操作指引：点击链接 -> 在打开的页面选择您的结算账户 -> 点击“设置账户”。${RESET}"
  echo -e "${RED}请确保为上面所有的项目都完成此操作！${RESET}"
  echo -e "${YELLOW}==========================================================${RESET}"
  
  read -p "当您为所有项目都关联好结算账户后，请按【回车键】继续..."
  
  # --- 第3部分：自动完成剩余工作 ---
  echo -e "\n${YELLOW}4. 正在为所有项目启用API并生成密钥...${RESET}"
  FINAL_SUMMARY="项目ID,API密钥\n"
  
  for PROJECT_ID in "${NEW_PROJECT_IDS[@]}"; do
    echo -e "\n--- 正在处理项目: ${BLUE}${PROJECT_ID}${RESET} ---"
    
    # 检查结算是否真的已关联
    echo "  (1/3) 正在验证结算状态..."
    BILLING_ENABLED=$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)")
    if [[ "$BILLING_ENABLED" != "True" ]]; then
      echo -e "  ${RED}✗ 结算未关联或未生效，跳过此项目。${RESET}"
      FINAL_SUMMARY+="${PROJECT_ID},结算未关联\n"
      continue
    fi
    echo -e "  ${GREEN}✓ 结算已关联。${RESET}"
    
    # 启用API
    echo "  (2/3) 正在启用 Generative Language API..."
    if ! gcloud services enable generativelanguage.googleapis.com --project="$PROJECT_ID" --quiet; then
      echo -e "  ${RED}✗ 启用API失败，跳过。${RESET}"
      FINAL_SUMMARY+="${PROJECT_ID},API启用失败\n"
      continue
    fi
    echo -e "  ${GREEN}✓ API已启用。${RESET}"
    
    # 生成密钥
    echo "  (3/3) 正在生成API密钥..."
    API_KEY=$(gcloud beta services api-keys create --display-name="Hybrid_Batch_Key_$(date +%s)" --project="$PROJECT_ID" --api-target=service=generativelanguage.googleapis.com --format="json(keyString)" | jq -r '.keyString')

    if [[ "$API_KEY" == AIzaSy* ]]; then
      echo -e "  ${GREEN}✓ API密钥生成成功！${RESET}"
      FINAL_SUMMARY+="${PROJECT_ID},${API_KEY}\n"
    else
      echo -e "  ${RED}✗ 密钥生成失败。${RESET}"
      FINAL_SUMMARY+="${PROJECT_ID},密钥生成失败\n"
    fi
  done
  
  # --- 第4部分：最终汇总 ---
  echo -e "\n\n${GREEN}✅ 所有任务完成！摘要如下：${RESET}"
  echo "====================================================================================="
  echo -e "${FINAL_SUMMARY}" | column -t -s ','
  echo "====================================================================================="
  echo -e "\n${YELLOW}请妥善保管您的API密钥。${RESET}"
  
  exit 0
}

# 运行主函数
main
