#!/bin/bash
# 文件名：vertex_setup.sh
# 功能：在Google Cloud Shell中创建Vertex AI项目并生成JSON密钥文件（美国区域）

# ======== 配置区 ========
PROJECT_PREFIX="ai-api"                     # 项目名前缀
DEFAULT_REGION="us-central1"                # 默认区域：美国中部（Gemini可用区）
SERVICE_ACCOUNT_NAME="vertex-automation"    # 服务账号名称
KEY_FILE_NAME="vertex-key.json"             # 密钥文件名

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
  
  # 创建项目
  echo -e "${YELLOW}步骤1/5：创建新项目 [${BLUE}${PROJECT_ID}${YELLOW}]${RESET}"
  gcloud projects create ${PROJECT_ID} --name="Vertex-AI-API"
  
  # 错误检查
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
  
  # 尝试关联结算账户（带错误处理）
  gcloud beta billing projects link ${PROJECT_ID} \
    --billing-account=${BILLING_ACCOUNT} || \
  echo -e "${YELLOW}结算账户关联失败，尝试使用其他账户${RESET}"
  
  # 如果关联失败，尝试使用其他可用账户
  if [ $? -ne 0 ]; then
    ALTERNATIVE_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | grep -v ${BILLING_ACCOUNT} | head -1)
    if [ -n "$ALTERNATIVE_ACCOUNT" ]; then
      echo -e "${YELLOW}使用备选结算账户: ${ALTERNATIVE_ACCOUNT}${RESET}"
      gcloud beta billing projects link ${PROJECT_ID} \
        --billing-account=${ALTERNATIVE_ACCOUNT}
    fi
  fi
  
  # 启用必需API（包含Gemini API）
  echo -e "${YELLOW}步骤3/5：启用API服务${RESET}"
  APIS=(
    "aiplatform.googleapis.com"           # Vertex AI API
    "generativelanguage.googleapis.com"   # Gemini API（关键添加）
    "cloudresourcemanager.googleapis.com"
    "serviceusage.googleapis.com"
    "iam.googleapis.com"
  )
  
  for api in "${APIS[@]}"; do
    echo -e " - 启用 ${BLUE}${api}${RESET}"
    gcloud services enable ${api} --quiet
    
    # 检查API启用状态
    if [ $? -ne 0 ]; then
      echo -e "${YELLOW}等待API启用状态传播...${RESET}"
      sleep 30  # 等待API状态刷新
      gcloud services enable ${api} --quiet
    fi
  done
  
  # 添加额外等待确保API完全启用
  echo -e "${YELLOW}等待API完全启用...${RESET}"
  sleep 20
  
  # 创建服务账号
  echo -e "${YELLOW}步骤4/5：配置访问权限${RESET}"
  SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  
  gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} \
    --display-name="Vertex-AI-Automation" \
    --project=${PROJECT_ID}
  
  # 授予Vertex AI权限
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/aiplatform.user" \
    --quiet
  
  # 额外授予Gemini API权限
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/aiplatform.serviceAgent" \
    --quiet
  
  # 生成JSON密钥文件
  echo -e "${YELLOW}步骤5/5：生成JSON密钥文件${RESET}"
  
  # 删除旧密钥文件（如果存在）
  if [ -f "$KEY_FILE_NAME" ]; then
    rm -f "$KEY_FILE_NAME"
  fi
  
  # 创建新密钥文件
  gcloud iam service-accounts keys create "$KEY_FILE_NAME" \
    --iam-account="$SERVICE_ACCOUNT_EMAIL" \
    --project="$PROJECT_ID"
  
  # 验证密钥文件
  if [ ! -f "$KEY_FILE_NAME" ]; then
    echo -e "${RED}密钥文件创建失败！${RESET}"
    echo "请尝试手动创建："
    echo "gcloud iam service-accounts keys create $KEY_FILE_NAME --iam-account=$SERVICE_ACCOUNT_EMAIL"
    exit 1
  fi
  
  # 打印结果
  echo -e "\n${GREEN}✅ 配置完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"
  echo -e "${BLUE}区域:${RESET}   ${DEFAULT_REGION} (美国中部)"
  echo -e "${BLUE}服务账号:${RESET} ${SERVICE_ACCOUNT_EMAIL}"
  echo "========================================"
  
  # 生成使用说明
  echo -e "\n${YELLOW}密钥文件已生成: ${BLUE}${KEY_FILE_NAME}${RESET}"
  echo -e "${YELLOW}下载方法：${RESET}"
  echo "1. 在左侧文件浏览器中，找到当前目录"
  echo "2. 右键点击 '${KEY_FILE_NAME}' 文件"
  echo "3. 选择 'Download'"
  echo ""
  echo "或者使用下载命令："
  echo -e "${BLUE}cloudshell download ${KEY_FILE_NAME}${RESET}"
  
  # 生成Python使用示例（使用美国区域）
  echo -e "\n${YELLOW}使用示例 (Python):${RESET}"
  cat <<EOL
from google.cloud import aiplatform

# 使用JSON密钥文件认证
aiplatform.init(
    project="${PROJECT_ID}",
    location="${DEFAULT_REGION}",  # 美国区域
    credentials="${KEY_FILE_NAME}"  # 指定密钥文件路径
)

# 测试Gemini API连接
from vertexai.preview.generative_models import GenerativeModel

model = GenerativeModel("gemini-1.5-pro")
response = model.generate_content("你好，世界！")
print(response.text)
EOL
  
  # 区域说明
  echo -e "\n${YELLOW}区域选择说明：${RESET}"
  echo "已设置美国中部(us-central1)区域，因为："
  echo "1. Gemini Pro/Flash模型在此区域全面可用"
  echo "2. 相比新加坡延迟更低（对北美用户）"
  echo "3. 支持所有最新模型功能"
  
  # 安全提示
  echo -e "\n${RED}⚠️ 安全提示：${RESET}"
  echo "1. 请妥善保管您的JSON密钥文件，不要泄露"
  echo "2. 密钥文件包含敏感信息，类似密码"
  echo "3. 如不慎泄露，请立即删除："
  echo "   https://console.cloud.google.com/iam-admin/serviceaccounts"
}

# 执行主函数
main
