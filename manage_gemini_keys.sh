#!/bin/bash
# 文件名：manage_gemini_keys.sh
# 功能：一个多功能的Gemini API密钥管理工具。
#       支持：1. 为单个项目创建密钥
#             2. 批量创建项目并生成密钥
#             3. 查询单个或所有项目的现有密钥

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
      error_exit "${tool} CLI 未安装。请先安装它。 (例如: sudo apt-get install ${tool} 或 brew install ${tool})"
    fi
  done
  
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '@'; then
    echo -e "${YELLOW}您尚未登录 gcloud。正在引导您登录...${RESET}"
    gcloud auth login --quiet || error_exit "gcloud 登录失败。"
    gcloud auth application-default login --quiet || error_exit "gcloud 应用默认凭证设置失败。"
  fi
  echo -e "${GREEN}✓ 依赖和登录状态正常。${RESET}"
}

# ======== 查询功能模块 ========

function query_single_project_keys() {
  echo -e "\n${YELLOW}正在获取GCP项目列表...${RESET}"
  PROJECT_LIST=$(gcloud projects list --format="value(projectId,name)" --sort-by=projectId)
  if [ -z "$PROJECT_LIST" ]; then echo -e "${RED}未找到任何GCP项目。${RESET}"; return; fi
  
  echo "发现以下项目:"; echo -e "${BLUE}"; awk '{print NR, $1, "(" $2 ")"}' <<< "$PROJECT_LIST"; echo -e "${RESET}"
  read -p "请选择要查询的项目编号: " CHOICE
  
  PROJECT_ID=$(echo "$PROJECT_LIST" | awk -v choice="$CHOICE" 'NR==choice {print $1}')
  if [ -z "$PROJECT_ID" ]; then echo -e "${RED}无效的选择。${RESET}"; return; fi
  
  echo -e "\n${YELLOW}正在查询项目 ${BLUE}${PROJECT_ID}${RESET} 的API密钥...${RESET}"
  KEYS_INFO=$(gcloud beta services api-keys list --project="$PROJECT_ID" --format="value(displayName,keyString)")
  
  if [ -z "$KEYS_INFO" ]; then
    echo -e "${GREEN}在项目 ${BLUE}${PROJECT_ID}${RESET} 中未找到任何API密钥。${RESET}"
  else
    echo -e "${GREEN}查询结果如下:${RESET}"; echo "====================================================================================="
    echo -e "${BLUE}显示名称\tAPI密钥${RESET}"; echo "$KEYS_INFO" | column -t
    echo "====================================================================================="
  fi
}

function query_all_projects_keys() {
  echo -e "\n${YELLOW}正在查询您账户下所有项目的API密钥... (这可能需要一些时间)${RESET}"
  ALL_PROJECTS=$(gcloud projects list --format="value(projectId)")
  if [ -z "$ALL_PROJECTS" ]; then echo -e "${RED}未找到任何GCP项目。${RESET}"; return; fi
  
  FINAL_SUMMARY="项目ID,密钥显示名称,API密钥\n"; FOUND_ANY_KEY=false
  
  for PROJECT_ID in $ALL_PROJECTS; do
    echo -e "  -> 正在扫描项目: ${BLUE}${PROJECT_ID}${RESET}..."
    KEYS_JSON=$(gcloud beta services api-keys list --project="$PROJECT_ID" --format="json" 2>/dev/null)
    
    if [ -n "$KEYS_JSON" ] && [ "$KEYS_JSON" != "[]" ]; then
      FOUND_ANY_KEY=true
      SUMMARY_PART=$(echo "$KEYS_JSON" | jq -r --arg pid "$PROJECT_ID" '.[] | "\($pid),\(.displayName),\(.keyString)"')
      FINAL_SUMMARY+="${SUMMARY_PART}\n"
    fi
  done
  
  if ! $FOUND_ANY_KEY; then
    echo -e "\n${GREEN}在您所有的项目中均未找到任何API密钥。${RESET}"
  else
    echo -e "\n${GREEN}✅ 所有项目扫描完成！汇总结果如下：${RESET}"
    echo "========================================================================================================"
    echo -e "${FINAL_SUMMARY}" | column -t -s ','
    echo "========================================================================================================"
  fi
}

# ======== 创建功能模块 ========

function create_single_key_flow() {
  # ... (此部分逻辑不变) ...
  echo -e "\n${YELLOW}正在获取GCP项目列表...${RESET}"
  PROJECT_LIST=$(gcloud projects list --format="value(projectId,name)" --sort-by=projectId)
  
  if [ -z "$PROJECT_LIST" ]; then
    echo "未找到任何GCP项目。"
    read -p "是否要现在创建一个新项目? (y/n): " CREATE_NEW
    if [[ "$CREATE_NEW" == "y" || "$CREATE_NEW" == "Y" ]]; then
      DEFAULT_PROJECT_ID="gemini-auto-project-$(date +%s)"
      read -p "请输入新项目的ID [默认为: ${DEFAULT_PROJECT_ID}]: " NEW_PROJECT_ID
      PROJECT_ID=${NEW_PROJECT_ID:-$DEFAULT_PROJECT_ID}
      echo -e "${YELLOW}正在创建项目 ${BLUE}${PROJECT_ID}${RESET}..."
      gcloud projects create "$PROJECT_ID" || { echo -e "${RED}项目创建失败。${RESET}"; return; }
    else
      echo -e "${RED}没有可用的项目。${RESET}"; return;
    fi
  else
    echo "发现以下项目:"; echo -e "${BLUE}"; awk '{print NR, $1, "(" $2 ")"}' <<< "$PROJECT_LIST"; echo -e "${RESET}"
    read -p "请选择要使用的项目编号 (或输入 'c' 创建新项目): " CHOICE
    
    if [[ "$CHOICE" == "c" || "$CHOICE" == "C" ]]; then
        DEFAULT_PROJECT_ID="gemini-auto-project-$(date +%s)"
        read -p "请输入新项目的ID [默认为: ${DEFAULT_PROJECT_ID}]: " NEW_PROJECT_ID
        PROJECT_ID=${NEW_PROJECT_ID:-$DEFAULT_PROJECT_ID}
        echo -e "${YELLOW}正在创建项目 ${BLUE}${PROJECT_ID}${RESET}..."
        gcloud projects create "$PROJECT_ID" || { echo -e "${RED}项目创建失败。${RESET}"; return; }
    else
        PROJECT_ID=$(echo "$PROJECT_LIST" | awk -v choice="$CHOICE" 'NR==choice {print $1}')
        if [ -z "$PROJECT_ID" ]; then echo -e "${RED}无效的选择。${RESET}"; return; fi
    fi
  fi
  echo -e "${GREEN}✓ 已选择项目: ${BLUE}${PROJECT_ID}${RESET}"
  gcloud config set project "$PROJECT_ID" --quiet || { echo -e "${RED}设置项目失败。${RESET}"; return; }

  BILLING_ENABLED=$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)")
  if [[ "$BILLING_ENABLED" == "False" ]]; then
    echo -e "${RED}警告: 项目 ${BLUE}${PROJECT_ID}${RESET}${RED} 未关联结算账户。${RESET}"
    echo "请访问此链接关联: ${BLUE}https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}${RESET}"
    read -p "是否仍然尝试继续? (y/n): " CONTINUE_ANYWAY
    if [[ "$CONTINUE_ANYWAY" != "y" && "$CONTINUE_ANYWAY" != "Y" ]]; then return; fi
  fi

  echo -e "\n${YELLOW}正在启用 Generative Language API...${RESET}"
  gcloud services enable generativelanguage.googleapis.com --project="$PROJECT_ID" --quiet || { echo -e "${RED}启用API失败。${RESET}"; return; }
  echo -e "${GREEN}✓ API已启用。${RESET}"
  
  echo -e "\n${YELLOW}正在生成API密钥...${RESET}"
  API_KEY=$(gcloud beta services api-keys create --display-name="Auto_Gemini_Key_$(date +%s)" --project="$PROJECT_ID" --api-target=service=generativelanguage.googleapis.com --format="json(keyString)" | jq -r '.keyString')

  if [[ "$API_KEY" == AIzaSy* ]]; then
    echo -e "\n${GREEN}✅ API密钥生成成功！${RESET}"
    echo "========================================"; echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"; echo -e "${BLUE}API密钥:${RESET} ${API_KEY}"; echo "========================================"
  else
    echo -e "${RED}❌ API密钥生成失败！请检查权限或结算状态。${RESET}"
  fi
}

function create_batch_keys_flow() {
  echo -e "\n${YELLOW}正在获取可用的结算账户列表...${RESET}"
  
  # --- 这是被修正的一行 ---
  # 将 DISPLAY_NAME 修改为 NAME
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --filter='OPEN' --format="value(ACCOUNT_ID, NAME)")
  # --- 修正结束 ---
  
  if [ -z "$BILLING_ACCOUNTS" ]; then
    echo -e "${RED}错误：未找到任何有效的结算账户。${RESET}"
    echo -e "${YELLOW}如果确认您有结算账户但此处未显示，可能是权限问题。${RESET}"
    echo -e "${YELLOW}请确保您的账号 (${BLUE}$(gcloud config get-value account)${YELLOW}) 拥有结算账户的 'Billing Account Viewer' 角色。${RESET}"
    return
  fi
  
  echo "发现以下有效的结算账户:"; echo -e "${BLUE}"; awk '{print NR, $0}' <<< "$BILLING_ACCOUNTS"; echo -e "${RESET}"
  read -p "请选择要用于新项目的结算账户编号: " CHOICE
  
  SELECTED_BILLING_ACCOUNT_ID=$(echo "$BILLING_ACCOUNTS" | awk -v choice="$CHOICE" 'NR==choice {print $1}')
  if [ -z "$SELECTED_BILLING_ACCOUNT_ID" ]; then echo -e "${RED}无效的选择。${RESET}"; return; fi
  echo -e "${GREEN}✓ 已选择结算账户: ${BLUE}${SELECTED_BILLING_ACCOUNT_ID}${RESET}"

  read -p "您想创建多少个新项目? " PROJECT_COUNT
  if ! [[ "$PROJECT_COUNT" =~ ^[1-9][0-9]*$ ]]; then echo -e "${RED}请输入一个大于0的有效数字。${RESET}"; return; fi
  
  FINAL_SUMMARY="项目ID,API密钥\n"; BASE_PROJECT_NAME="gemini-batch-$(date +%Y%m%d)"
  
  for i in $(seq 1 "$PROJECT_COUNT"); do
    PROJECT_ID="${BASE_PROJECT_NAME}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    echo -e "\n${YELLOW}--- [${i}/${PROJECT_COUNT}] 正在处理项目: ${BLUE}${PROJECT_ID}${RESET} ---"
    
    echo "  (1/4) 正在创建项目..."
    if ! gcloud projects create "$PROJECT_ID" --quiet; then
      echo -e "  ${RED}项目创建失败，跳过。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},项目创建失败\n"; continue; fi
    
    echo "  (2/4) 正在关联结算账户..."
    if ! gcloud beta billing projects link "$PROJECT_ID" --billing-account="$SELECTED_BILLING_ACCOUNT_ID" --quiet; then
      echo -e "  ${RED}关联结算失败，跳过。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},关联结算失败\n"; continue; fi
    
    echo "  (3/4) 正在启用 API..."; sleep 5
    if ! gcloud services enable generativelanguage.googleapis.com --project="$PROJECT_ID" --quiet; then
      echo -e "  ${RED}启用API失败，跳过。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},API启用失败\n"; continue; fi
    
    echo "  (4/4) 正在生成API密钥..."
    API_KEY=$(gcloud beta services api-keys create --display-name="Batch_Gemini_Key_$(date +%s)" --project="$PROJECT_ID" --api-target=service=generativelanguage.googleapis.com --format="json(keyString)" | jq -r '.keyString')

    if [[ "$API_KEY" == AIzaSy* ]]; then
      echo -e "  ${GREEN}✓ API密钥生成成功！${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},${API_KEY}\n"
    else
      echo -e "  ${RED}API密钥生成失败。${RESET}"; FINAL_SUMMARY+="${PROJECT_ID},密钥生成失败\n"
    fi
  done

  echo -e "\n\n${GREEN}✅ 所有任务完成！摘要如下：${RESET}"
  echo "====================================================================================="
  echo -e "${FINAL_SUMMARY}" | column -t -s ','
  echo "====================================================================================="
}

# ======== 主菜单和主函数 ========

function main_menu() {
  clear
  echo -e "${YELLOW}========== Gemini API 密钥管理器 ==========${RESET}"
  echo -e "${GREEN}请选择您要执行的操作:${RESET}"
  echo "-------------------------------------------"
  echo -e "  ${BLUE}1.${RESET} 创建新的API密钥 (单个项目)"
  echo -e "  ${BLUE}2.${RESET} 批量创建项目和密钥"
  echo "-------------------------------------------"
  echo -e "  ${BLUE}3.${RESET} 查询单个项目的API密钥"
  echo -e "  ${BLUE}4.${RESET} 查询所有项目的API密钥"
  echo "-------------------------------------------"
  echo -e "  ${RED}5.${RESET} 退出"
  echo "==========================================="
  read -p "请输入选项 [1-5]: " CHOICE
  
  case $CHOICE in
    1) create_single_key_flow; press_any_key_to_continue ;;
    2) create_batch_keys_flow; press_any_key_to_continue ;;
    3) query_single_project_keys; press_any_key_to_continue ;;
    4) query_all_projects_keys; press_any_key_to_continue ;;
    5) echo -e "\n${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
    *) echo -e "\n${RED}无效的输入，请输入 1 到 5 之间的数字。${RESET}"; sleep 2 ;;
  esac
}

function main() {
  check_dependencies
  while true; do
    main_menu
  done
}

main
