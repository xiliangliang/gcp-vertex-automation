#!/bin/bash
# 文件名：vertex_setup.sh
# 修复版：解决项目创建和权限问题

# ======== 配置区 ========
PROJECT_PREFIX="ai-api"                     # 项目名前缀
DEFAULT_REGION="asia-southeast1"            # 默认区域：新加坡
SERVICE_ACCOUNT_NAME="vertex-automation"    # 服务账号名称

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ===== 函数：生成随机ID =====
generate_random_id() {
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6
}

# ===== 函数：获取结算账号ID =====
get_billing_account() {
  echo -e "${YELLOW}正在获取结算账号...${RESET}"
  
  # 获取所有可用的结算账号
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" 2>/dev/null)
  
  if [ -z "$BILLING_ACCOUNTS" ]; then
    echo -e "${RED}未找到有效的结算账号！${RESET}"
    echo "请确认："
    echo "1. 您有有效的GCP结算账号"
    echo "2. 在控制台创建结算账号：https://console.cloud.google.com/billing"
    exit 1
  fi
  
  # 如果有多个结算账号，选择第一个
  BILLING_ACCOUNT=$(echo $BILLING_ACCOUNTS | awk '{print $1}')
  echo -e "${GREEN}✓ 使用结算账号: ${BLUE}${BILLING_ACCOUNT}${RESET}"
}

# ===== 主执行流程 =====
main() {
  # 检查是否在Cloud Shell中
  if [ -z "$CLOUD_SHELL" ]; then
    echo -e "${RED}错误：请在Google Cloud Shell中运行此脚本${RESET}"
    echo "访问：https://shell.cloud.google.com"
    exit 1
  fi
  
  echo -e "${GREEN}✓ 检测到Cloud Shell环境${RESET}"
  
  # 获取结算账号
  get_billing_account
  
  # 生成唯一项目ID
  RANDOM_SUFFIX=$(generate_random_id)
  PROJECT_ID="${PROJECT_PREFIX}-${RANDOM_SUFFIX}"
  
  # ===== 修复点1：使用合规项目名称 =====
  echo -e "${YELLOW}步骤1/5：创建新项目 [${BLUE}${PROJECT_ID}${YELLOW}]${RESET}"
  gcloud projects create ${PROJECT_ID} --name="Vertex-AI-API"
  
  # ===== 修复点2：添加错误检查 =====
  if [ $? -ne 0 ]; then
    echo -e "${RED}项目创建失败！请检查：${RESET}"
    echo "1. 项目显示名称必须使用字母、数字和连字符"
    echo "2. 不能包含空格或特殊字符"
    echo "3. 长度建议6-30个字符"
    exit 1
  fi
  
  # 设置当前项目
  echo -e "${YELLOW}步骤2/5：配置项目结算${RESET}"
  gcloud config set project ${PROJECT_ID}
  gcloud beta billing projects link ${PROJECT_ID} \
    --billing-account=${BILLING_ACCOUNT}
  
  # 启用必需API
  echo -e "${YELLOW}步骤3/5：启用API服务${RESET}"
  APIS=(
    "aiplatform.googleapis.com"       # Vertex AI API
    "cloudresourcemanager.googleapis.com"
    "serviceusage.googleapis.com"
    "iam.googleapis.com"
  )
  
  for api in "${APIS[@]}"; do
    echo -e " - 启用 ${BLUE}${api}${RESET}"
    gcloud services enable ${api} --quiet
    
    # 检查API启用状态
    if [ $? -ne 0 ]; then
      echo -e "${RED}启用 ${api} 失败！${RESET}"
      echo "尝试手动启用："
      echo "gcloud services enable ${api} --project=${PROJECT_ID}"
    fi
  done
  
  # 创建服务账号
  echo -e "${YELLOW}步骤4/5：配置访问权限${RESET}"
  SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  
  gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} \
    --display-name="Vertex-AI-Automation" \
    --project=${PROJECT_ID}
  
  # 授予权限
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/aiplatform.user" \
    --quiet
  
  # 生成API密钥
  echo -e "${YELLOW}步骤5/5：创建API密钥${RESET}"
  API_KEY_DATA=$(gcloud beta services api-keys create \
    --display-name="Vertex_Auto_Key" \
    --api-target=service=aiplatform.googleapis.com \
    --quiet 2>&1)
  
  # ===== 修复点3：更可靠的密钥提取 =====
  API_KEY=$(echo "${API_KEY_DATA}" | grep -Eo 'key: [a-zA-Z0-9_-]{39}' | cut -d' ' -f2)
  
  if [ -z "$API_KEY" ]; then
    echo -e "${RED}API密钥生成失败！${RESET}"
    echo "原始响应："
    echo "$API_KEY_DATA"
    exit 1
  fi
  
  # 打印结果
  echo -e "\n${GREEN}✅ 配置完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"
  echo -e "${BLUE}区域:${RESET}   ${DEFAULT_REGION}"
  echo -e "${BLUE}API密钥:${RESET} ${API_KEY}"
  echo "========================================"
  
  # 生成使用示例
  echo -e "\n${YELLOW}使用示例 (Python):${RESET}"
  cat <<EOL
from google.cloud import aiplatform

aiplatform.init(
    project="${PROJECT_ID}",
    location="${DEFAULT_REGION}",
    api_key="${API_KEY}"
)

# 测试API连接
endpoint = aiplatform.Endpoint("")
print("Vertex API 连接成功!")
EOL
  
  # 安全提示
  echo -e "\n${RED}⚠️ 安全提示：${RESET}"
  echo "1. 请妥善保管您的API密钥"
  echo "2. 建议配置访问限制：https://console.cloud.google.com/apis/credentials/key/${API_KEY}"
}

# 执行主函数
main
