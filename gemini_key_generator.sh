#!/bin/bash
# 文件名：gemini_key_generator.sh
# 功能：在Google Cloud Shell中生成Gemini API密钥并提供下载

# ======== 配置区 ========
OUTPUT_FILE="gemini_api_key.txt"   # 输出文件名
MAX_RETRIES=5                      # 最大重试次数
WAIT_SECONDS=10                    # 重试等待时间

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ===== 函数：生成API密钥 =====
generate_gemini_key() {
  local project_id=$1
  local retry_count=0
  
  while [ $retry_count -lt $MAX_RETRIES ]; do
    echo -e "${YELLOW}尝试生成API密钥 ($((retry_count+1))/$MAX_RETRIES)...${RESET}"
    
    # 尝试创建API密钥
    API_KEY_DATA=$(gcloud beta services api-keys create \
      --display-name="Gemini_Pro_Key" \
      --api-target=service=generativelanguage.googleapis.com \
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
    
    # 增加重试计数
    retry_count=$((retry_count+1))
    
    # 如果不是最后一次尝试，则等待
    if [ $retry_count -lt $MAX_RETRIES ]; then
      echo -e "${YELLOW}等待${WAIT_SECONDS}秒后重试...${RESET}"
      sleep $WAIT_SECONDS
    fi
  done
  
  echo -e "${RED}API密钥生成失败！${RESET}"
  return 1
}

# ===== 函数：启用必需API =====
enable_required_apis() {
  echo -e "${YELLOW}启用Generative Language API...${RESET}"
  
  # 尝试启用API
  gcloud services enable generativelanguage.googleapis.com --quiet
  
  # 检查是否成功
  if [ $? -ne 0 ]; then
    echo -e "${YELLOW}等待API状态传播...${RESET}"
    sleep 20
    gcloud services enable generativelanguage.googleapis.com --quiet
  fi
  
  echo -e "${GREEN}✓ API已启用${RESET}"
}

# ===== 主执行流程 =====
main() {
  # 检查是否在Cloud Shell中
  if [ -z "$CLOUD_SHELL" ]; then
    echo -e "${RED}错误：请在Google Cloud Shell中运行此脚本${RESET}"
    echo "访问：https://shell.cloud.google.com"
    exit 1
  fi
  
  echo -e "${GREEN}=== Gemini API密钥生成器 ===${RESET}"
  
  # 检查jq是否安装
  if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}安装jq JSON处理工具...${RESET}"
    sudo apt-get update -qq > /dev/null
    sudo apt-get install -y jq > /dev/null
  fi
  
  # 获取当前项目ID
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  
  if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}未找到活动项目！${RESET}"
    echo "请设置活动项目："
    echo "1. 访问: https://console.cloud.google.com/"
    echo "2. 创建或选择项目"
    echo "3. 运行: gcloud config set project YOUR_PROJECT_ID"
    exit 1
  fi
  
  echo -e "${BLUE}使用项目: ${PROJECT_ID}${RESET}"
  
  # 启用必需API
  enable_required_apis
  
  # 生成API密钥
  echo -e "${YELLOW}生成Gemini API密钥...${RESET}"
  API_KEY=$(generate_gemini_key $PROJECT_ID)
  
  if [ -z "$API_KEY" ]; then
    echo -e "${RED}密钥生成失败，请尝试以下解决方案：${RESET}"
    echo "1. 确保项目已关联结算账户"
    echo "2. 手动启用API: https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com"
    echo "3. 检查配额限制: https://console.cloud.google.com/iam-admin/quotas"
    exit 1
  fi
  
  # 创建密钥文件
  echo "$API_KEY" > "$OUTPUT_FILE"
  
  # 打印结果
  echo -e "\n${GREEN}✅ Gemini API密钥已生成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"
  echo -e "${BLUE}API密钥:${RESET} ${API_KEY}"
  echo -e "${BLUE}保存至:${RESET} ${OUTPUT_FILE}"
  echo "========================================"
  
  # 自动下载文件
  echo -e "\n${YELLOW}正在下载API密钥文件...${RESET}"
  if cloudshell download "$OUTPUT_FILE"; then
    echo -e "${GREEN}✓ 下载已启动！${RESET}"
  else
    echo -e "${YELLOW}自动下载失败，请手动下载：${RESET}"
    echo "1. 在左侧文件浏览器中，找到当前目录"
    echo "2. 右键点击 '${OUTPUT_FILE}' 文件"
    echo "3. 选择 'Download'"
  fi
  
  # 生成使用示例
  echo -e "\n${YELLOW}使用示例 (Python):${RESET}"
  cat <<EOL
import google.generativeai as genai

# 配置API密钥
genai.configure(api_key="${API_KEY}")

# 创建模型实例（支持最新Gemini模型）
model = genai.GenerativeModel('gemini-1.5-pro')  # 当gemini-2.5可用时替换为'gemini-2.5-pro'

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
  echo "3. 删除不再使用的密钥"
}

# 执行主函数
main
