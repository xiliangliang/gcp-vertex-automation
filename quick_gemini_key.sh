#!/bin/bash
# 文件名：enhanced_gemini_key.sh
# 功能：全自动、交互式地获取或创建项目，并生成Gemini API密钥

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# 函数：打印错误信息并退出
function error_exit() {
  echo -e "\n${RED}❌ 错误: $1${RESET}\n"
  exit 1
}

# 函数：检查依赖工具和登录状态
function check_dependencies() {
  echo -e "${YELLOW}1. 正在检查依赖工具...${RESET}"
  if ! command -v gcloud &> /dev/null; then
    error_exit "gcloud CLI 未安装。请访问 https://cloud.google.com/sdk/docs/install 进行安装。"
  fi
  if ! command -v jq &> /dev/null; then
    error_exit "jq 未安装。请使用您的包管理器安装 (例如: sudo apt-get install jq 或 brew install jq)。"
  fi
  
  # 检查登录状态
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '@'; then
    echo -e "${YELLOW}您尚未登录 gcloud。正在引导您登录...${RESET}"
    gcloud auth login --quiet || error_exit "gcloud 登录失败。"
    gcloud auth application-default login --quiet || error_exit "gcloud 应用默认凭证设置失败。"
  fi
  echo -e "${GREEN}✓ 依赖和登录状态正常。${RESET}"
}

# 函数：选择或创建项目
function select_or_create_project() {
  echo -e "\n${YELLOW}2. 正在获取GCP项目列表...${RESET}"
  PROJECT_LIST=$(gcloud projects list --format="value(projectId,name)" --sort-by=projectId)
  
  if [ -z "$PROJECT_LIST" ]; then
    echo "未找到任何GCP项目。"
    read -p "是否要现在创建一个新项目? (y/n): " CREATE_NEW
    if [[ "$CREATE_NEW" == "y" || "$CREATE_NEW" == "Y" ]]; then
      DEFAULT_PROJECT_ID="gemini-auto-project-$(date +%s)"
      read -p "请输入新项目的ID [默认为: ${DEFAULT_PROJECT_ID}]: " NEW_PROJECT_ID
      PROJECT_ID=${NEW_PROJECT_ID:-$DEFAULT_PROJECT_ID}
      echo -e "${YELLOW}正在创建项目 ${BLUE}${PROJECT_ID}${RESET}..."
      gcloud projects create "$PROJECT_ID" || error_exit "项目创建失败。"
    else
      error_exit "没有可用的项目。请先在 https://console.cloud.google.com/projectcreate 创建一个项目。"
    fi
  else
    echo "发现以下项目:"
    echo -e "${BLUE}"
    awk '{print NR, $1, "(" $2 ")"}' <<< "$PROJECT_LIST"
    echo -e "${RESET}"
    read -p "请选择要使用的项目编号 (或输入 'c' 创建新项目): " CHOICE
    
    if [[ "$CHOICE" == "c" || "$CHOICE" == "C" ]]; then
        DEFAULT_PROJECT_ID="gemini-auto-project-$(date +%s)"
        read -p "请输入新项目的ID [默认为: ${DEFAULT_PROJECT_ID}]: " NEW_PROJECT_ID
        PROJECT_ID=${NEW_PROJECT_ID:-$DEFAULT_PROJECT_ID}
        echo -e "${YELLOW}正在创建项目 ${BLUE}${PROJECT_ID}${RESET}..."
        gcloud projects create "$PROJECT_ID" || error_exit "项目创建失败。"
    else
        PROJECT_ID=$(echo "$PROJECT_LIST" | awk -v choice="$CHOICE" 'NR==choice {print $1}')
        if [ -z "$PROJECT_ID" ]; then
            error_exit "无效的选择。"
        fi
    fi
  fi
  
  echo -e "${GREEN}✓ 已选择项目: ${BLUE}${PROJECT_ID}${RESET}"
  gcloud config set project "$PROJECT_ID" --quiet || error_exit "设置项目失败。"
}

# 函数：检查结算账户
function check_billing() {
  echo -e "\n${YELLOW}3. 正在检查项目结算状态...${RESET}"
  BILLING_ENABLED=$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)")
  
  if [[ "$BILLING_ENABLED" == "False" ]]; then
    echo -e "${RED}警告: 项目 ${BLUE}${PROJECT_ID}${RESET}${RED} 未关联有效的结算账户。${RESET}"
    echo "启用API和生成密钥可能会失败。"
    echo "请访问此链接关联结算账户: ${BLUE}https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}${RESET}"
    read -p "是否仍然尝试继续? (y/n): " CONTINUE_ANYWAY
    if [[ "$CONTINUE_ANYWAY" != "y" && "$CONTINUE_ANYWAY" != "Y" ]]; then
      error_exit "操作已由用户取消。"
    fi
  else
    echo -e "${GREEN}✓ 项目已关联结算账户。${RESET}"
  fi
}

# 主函数
function main() {
  echo -e "${YELLOW}=== Gemini API密钥生成器 (全自动增强版) ===${RESET}"
  
  check_dependencies
  select_or_create_project
  check_billing
  
  echo -e "\n${YELLOW}4. 正在启用 Generative Language API...${RESET}"
  if ! gcloud services enable generativelanguage.googleapis.com --quiet; then
    error_exit "启用 Generative Language API 失败。请检查权限或结算状态。"
  fi
  echo -e "${GREEN}✓ API已启用。${RESET}"
  
  echo -e "\n${YELLOW}5. 正在生成API密钥...${RESET}"
  # 使用 --format=json(keyString) 直接获取密钥字符串，更高效
  API_KEY=$(gcloud beta services api-keys create \
    --display-name="Auto_Gemini_Key_$(date +%s)" \
    --project="$PROJECT_ID" \
    --api-target=service=generativelanguage.googleapis.com \
    --format="json(keyString)" | jq -r '.keyString')

  if [[ "$API_KEY" == AIzaSy* ]]; then
    echo -e "\n${GREEN}✅ API密钥生成成功！${RESET}"
    echo "========================================"
    echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"
    echo -e "${BLUE}API密钥:${RESET} ${API_KEY}"
    echo "========================================"
    
    echo -e "\n${YELLOW}Python 使用示例:${RESET}"
    cat <<EOL
import google.generativeai as genai

genai.configure(api_key="${API_KEY}")

# 更多模型配置请参考: https://ai.google.dev/api/python/google/generativeai/GenerativeModel
model = genai.GenerativeModel('gemini-1.5-flash') # 或者 'gemini-pro'
response = model.generate_content("你好，Gemini！")
print(response.text)
EOL
    exit 0
  else
    echo -e "${RED}❌ API密钥生成失败！${RESET}"
    echo "请检查以下几点："
    echo "1. 确保您的账户有 'API Keys Admin' (roles/apikeys.admin) 权限。"
    echo "2. 确保项目已正确关联有效的结算账户。"
    echo "3. 尝试手动访问以下链接创建密钥："
    echo -e "${BLUE}https://console.cloud.google.com/apis/credentials/key/generativelanguage.googleapis.com?project=${PROJECT_ID}${RESET}"
    exit 1
  fi
}

# 运行主函数
main
