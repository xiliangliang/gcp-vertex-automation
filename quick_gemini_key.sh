#!/bin/bash
# 文件名：quick_gemini_key.sh
# 功能：快速获取第一个项目并生成Gemini API密钥

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

echo -e "${YELLOW}=== Gemini API密钥生成器 (快速版) ===${RESET}"

# 获取第一个项目
PROJECT_ID=$(gcloud projects list --format="value(projectId)" | head -1)

if [ -z "$PROJECT_ID" ]; then
  echo -e "${RED}错误：未找到任何项目！${RESET}"
  echo "请先创建项目："
  echo "1. 访问: https://console.cloud.google.com/projectcreate"
  echo "2. 创建新项目"
  exit 1
fi

echo -e "${GREEN}✓ 使用项目: ${BLUE}${PROJECT_ID}${RESET}"

# 设置当前项目
gcloud config set project $PROJECT_ID --quiet

# 启用API（简单尝试）
echo -e "${YELLOW}启用Generative Language API...${RESET}"
gcloud services enable generativelanguage.googleapis.com --quiet

# 生成API密钥
echo -e "${YELLOW}生成API密钥...${RESET}"
API_KEY_DATA=$(gcloud beta services api-keys create \
  --display-name="Quick_Gemini_Key" \
  --api-target=service=generativelanguage.googleapis.com \
  --format=json)

# 提取密钥
if [ -n "$API_KEY_DATA" ]; then
  API_KEY=$(echo "$API_KEY_DATA" | jq -r '.[].keyString' 2>/dev/null)
  
  if [[ "$API_KEY" == AIzaSy* ]]; then
    echo -e "\n${GREEN}✅ API密钥生成成功！${RESET}"
    echo "========================================"
    echo -e "${BLUE}项目ID:${RESET} ${PROJECT_ID}"
    echo -e "${BLUE}API密钥:${RESET} ${API_KEY}"
    echo "========================================"
    
    # 使用示例
    echo -e "\n${YELLOW}Python 使用示例:${RESET}"
    cat <<EOL
import google.generativeai as genai

genai.configure(api_key="${API_KEY}")

model = genai.GenerativeModel('gemini-pro')
response = model.generate_content("你好，Gemini！")
print(response.text)
EOL
    exit 0
  fi
fi

echo -e "${RED}❌ API密钥生成失败！${RESET}"
echo "可能原因："
echo "1. 项目未关联结算账户"
echo "2. 缺少必要权限"
echo "3. API服务未启用"
echo "解决方案："
echo "1. 关联结算账户: https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}"
echo "2. 手动启用API: https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com"
