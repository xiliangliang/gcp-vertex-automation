#!/bin/bash
# 文件名：vertex_setup.sh
# 功能：在Google Cloud Shell中创建Vertex AI项目并生成API密钥

# ======== 配置区 ========
PROJECT_PREFIX="vertex-api"                 # 项目名前缀
DEFAULT_REGION="us-central1"                # 默认区域
SERVICE_ACCOUNT_NAME="vertex-automation"    # 服务账号名称
CONFIG_FILE_NAME="vertex-config.json"       # 配置文件名称
KEY_FILE_NAME="vertex-key.json"             # 服务账号密钥文件名
MAX_PROJECTS=5                              # 最大允许创建的项目数

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

# ===== 结算状态验证函数 =====
check_billing_status() {
  local project_id=$1
  local max_retries=8
  local wait_seconds=15
  
  echo -e "${YELLOW}验证结算状态...${RESET}"
  
  for ((i=1; i<=max_retries; i++)); do
    # 检查结算状态
    billing_status=$(gcloud beta billing projects describe $project_id \
      --format="value(billingEnabled)" 2>/dev/null)
    
    if [ "$billing_status" = "True" ]; then
      echo -e "${GREEN}✓ 结算已启用${RESET}"
      return 0
    fi
    
    echo -e "${YELLOW}等待结算状态生效 ($i/$max_retries)...${RESET}"
    sleep $wait_seconds
  done
  
  # 最终检查
  billing_status=$(gcloud beta billing projects describe $project_id \
    --format="value(billingEnabled)" 2>/dev/null)
    
  if [ "$billing_status" = "True" ]; then
    echo -e "${GREEN}✓ 结算已启用${RESET}"
    return 0
  fi
  
  echo -e "${RED}结算启用失败！${RESET}"
  return 1
}

# ===== 生成API密钥 =====
generate_api_key() {
  local project_id=$1
  local max_retries=5
  local wait_seconds=10
  
  echo -e "${YELLOW}生成API密钥...${RESET}"
  
  for ((i=1; i<=max_retries; i++)); do
    # 尝试创建API密钥
    API_KEY_DATA=$(gcloud beta services api-keys create \
      --display-name="Vertex_Auto_Key" \
      --api-target=service=aiplatform.googleapis.com \
      --format=json \
      --quiet 2>/dev/null)
    
    if [ -n "$API_KEY_DATA" ]; then
      # 提取密钥
      API_KEY=$(echo "$API_KEY_DATA" | jq -r '.[].keyString' 2>/dev/null)
      
      if [[ "$API_KEY" == AIzaSy* ]]; then
        echo -e "${GREEN}✓ API密钥生成成功${RESET}"
        echo "$API_KEY"
        return 0
      fi
    fi
    
    echo -e "${YELLOW}密钥生成失败 ($i/$max_retries)，等待${wait_seconds}秒后重试...${RESET}"
    sleep $wait_seconds
  done
  
  echo -e "${RED}API密钥生成失败！${RESET}"
  return 1
}

# ===== 检查项目配额 =====
check_project_quota() {
  echo -e "${YELLOW}检查项目配额...${RESET}"
  
  # 获取当前项目数量
  CURRENT_PROJECTS=$(gcloud projects list --format="value(projectId)" | wc -l)
  
  if [ "$CURRENT_PROJECTS" -ge "$MAX_PROJECTS" ]; then
    echo -e "${RED}错误：已达到项目配额上限 ($MAX_PROJECTS个项目)${RESET}"
    echo "解决方案："
    echo "1. 删除不再使用的项目：https://console.cloud.google.com/cloud-resource-manager"
    echo "2. 等待24小时让配额重置"
    exit 1
  fi
  
  echo -e "${GREEN}✓ 当前项目数: $CURRENT_PROJECTS/$MAX_PROJECTS${RESET}"
}

# ===== 主执行流程 =====
main() {
  # 检查是否在Cloud Shell中
  if [ -z "$CLOUD_SHELL" ]; then
    echo -e "${RED}错误：请在Google Cloud Shell中运行此脚本${RESET}"
    echo "访问：https://shell.cloud.google.com"
    exit 1
  fi
  
  # 检查jq是否安装
  if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}安装jq JSON处理工具...${RESET}"
    sudo apt-get update -qq > /dev/null
    sudo apt-get install -y jq > /dev/null
  fi
  
  echo -e "${GREEN}✓ 检测到Cloud Shell环境${RESET}"
  
  # 检查项目配额
  check_project_quota
  
  # 获取结算账号
  get_billing_account
  
  # 生成唯一项目ID
  RANDOM_SUFFIX=$(generate_random_id)
  PROJECT_ID="${PROJECT_PREFIX}-${RANDOM_SUFFIX}"
  
  # 创建项目
  echo -e "${YELLOW}步骤1/6：创建新项目 [${BLUE}${PROJECT_ID}${YELLOW}]${RESET}"
  gcloud projects create ${PROJECT_ID} --name="Vertex-AI-API"
  
  # 错误检查
  if [ $? -ne 0 ]; then
    echo -e "${RED}项目创建失败！请检查：${RESET}"
    echo "1. 项目ID必须全局唯一（尝试添加更多随机字符）"
    echo "2. 项目名称格式：小写字母、数字和连字符"
    exit 1
  fi
  
  # 设置当前项目
  echo -e "${YELLOW}步骤2/6：配置项目结算${RESET}"
  gcloud config set project ${PROJECT_ID}
  
  # 尝试关联主结算账户
  echo "关联结算账户: ${BILLING_ACCOUNT}"
  ERROR_MESSAGE=$(gcloud beta billing projects link ${PROJECT_ID} \
    --billing-account=${BILLING_ACCOUNT} 2>&1)
  
  # 检查错误类型
  if [ $? -ne 0 ]; then
    if [[ "$ERROR_MESSAGE" == *"quota"* ]]; then
      echo -e "${RED}结算账户已达项目配额上限！${RESET}"
      echo "解决方案："
      echo "1. 删除不再使用的项目：https://console.cloud.google.com/cloud-resource-manager"
      echo "2. 联系GCP支持增加配额：https://cloud.google.com/docs/quota"
      exit 1
    else
      echo -e "${YELLOW}主结算账户关联失败，尝试备选账户${RESET}"
      ALTERNATIVE_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | grep -v ${BILLING_ACCOUNT} | head -1)
      
      if [ -n "$ALTERNATIVE_ACCOUNT" ]; then
        echo -e "尝试备选结算账户: ${ALTERNATIVE_ACCOUNT}"
        gcloud beta billing projects link ${PROJECT_ID} \
          --billing-account=${ALTERNATIVE_ACCOUNT} 2>/dev/null
      fi
    fi
  fi
  
  # 验证结算状态
  if ! check_billing_status $PROJECT_ID; then
    # 提供手动修复链接
    MANUAL_BILLING_LINK="https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}"
    echo -e "${RED}结算启用失败，请手动操作：${RESET}"
    echo "1. 访问: ${MANUAL_BILLING_LINK}"
    echo "2. 点击 '更改结算账户'"
    echo "3. 选择有效的结算账户"
    echo "4. 等待5分钟后重新运行脚本"
    exit 1
  fi
  
  # 添加额外等待确保结算状态传播
  echo -e "${YELLOW}步骤3/6：等待结算状态完全生效（30秒）...${RESET}"
  sleep 30
  
  # 启用必需API
  echo -e "${YELLOW}步骤4/6：启用API服务${RESET}"
  APIS=(
    "aiplatform.googleapis.com"           # Vertex AI API
    "generativelanguage.googleapis.com"   # Gemini API
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
  echo -e "${YELLOW}等待API完全启用（20秒）...${RESET}"
  sleep 20
  
  # 创建服务账号
  echo -e "${YELLOW}步骤5/6：配置访问权限${RESET}"
  SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  
  gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} \
    --display-name="Vertex-AI-Automation" \
    --project=${PROJECT_ID}
  
  # 授予Vertex AI权限
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/aiplatform.user" \
    --quiet
  
  # 额外授予服务代理权限
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/aiplatform.serviceAgent" \
    --quiet
  
  # 生成服务账号密钥文件
  echo -e "${YELLOW}步骤6/6：生成配置文件${RESET}"
  
  # 删除旧文件（如果存在）
  rm -f "$KEY_FILE_NAME" "$CONFIG_FILE_NAME" 2>/dev/null
  
  # 创建服务账号密钥文件
  gcloud iam service-accounts keys create "$KEY_FILE_NAME" \
    --iam-account="$SERVICE_ACCOUNT_EMAIL" \
    --project="$PROJECT_ID"
  
  # 生成API密钥
  API_KEY=$(generate_api_key $PROJECT_ID)
  
  # 创建配置文件（简化版）
  cat > "$CONFIG_FILE_NAME" <<EOL
{
  "project_id": "${PROJECT_ID}",
  "region": "${DEFAULT_REGION}",
  "service_account_email": "${SERVICE_ACCOUNT_EMAIL}",
  "api_key": "${API_KEY}",
  "key_file": "${KEY_FILE_NAME}",
  "timestamp": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOL

  # 验证配置文件
  if [ ! -f "$CONFIG_FILE_NAME" ]; then
    echo -e "${RED}配置文件创建失败！${RESET}"
    exit 1
  fi

  # 打印结果
  echo -e "\n${GREEN}✅ Vertex AI配置完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"
  echo -e "${BLUE}区域:${RESET}   ${DEFAULT_REGION}"
  echo -e "${BLUE}API密钥:${RESET} ${API_KEY}"
  echo -e "${BLUE}配置文件:${RESET} ${CONFIG_FILE_NAME}"
  echo -e "${BLUE}密钥文件:${RESET} ${KEY_FILE_NAME}"
  echo "========================================"
  
  # 显示配置文件内容
  echo -e "\n${YELLOW}配置文件内容：${RESET}"
  cat "$CONFIG_FILE_NAME" | jq .
  
  # 自动下载配置文件
  echo -e "\n${YELLOW}正在下载配置文件...${RESET}"
  if cloudshell download $CONFIG_FILE_NAME; then
    echo -e "${GREEN}✓ 配置文件下载已启动！${RESET}"
  else
    echo -e "${YELLOW}自动下载失败，请手动下载：${RESET}"
    echo "1. 在左侧文件浏览器中，找到当前目录"
    echo "2. 右键点击 '${CONFIG_FILE_NAME}' 文件"
    echo "3. 选择 'Download'"
  fi
  
  # 生成Python使用示例
  echo -e "\n${YELLOW}Vertex AI使用示例 (Python):${RESET}"
  cat <<EOL
import vertexai
from vertexai.generative_models import GenerativeModel

# 方法1：使用API密钥认证
vertexai.init(project="YOUR_PROJECT_ID", location="us-central1", api_key="YOUR_API_KEY")

# 方法2：使用服务账号密钥文件（推荐）
# vertexai.init(project="YOUR_PROJECT_ID", location="us-central1", credentials="vertex-key.json")

# 创建模型实例
model = GenerativeModel("gemini-1.5-pro")

# 生成内容
response = model.generate_content("请解释量子计算的基本原理")
print(response.text)

# 流式响应
stream_response = model.generate_content(
    "用简单的语言解释神经网络如何工作",
    stream=True
)

for chunk in stream_response:
    print(chunk.text, end="")
EOL
  
  # 安全提示
  echo -e "\n${RED}⚠️ 安全提示：${RESET}"
  echo "1. 请妥善保管您的API密钥，不要泄露"
  echo "2. 定期轮换密钥：https://console.cloud.google.com/apis/credentials"
  echo "3. 限制密钥使用范围：https://cloud.google.com/docs/authentication/api-keys"
}

# 执行主函数
main
