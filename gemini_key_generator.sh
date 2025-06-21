#!/bin/bash
# 文件名：gemini_key_factory.sh
# 功能：批量创建项目并生成Gemini API密钥

# ======== 配置区 ========
PROJECT_PREFIX="gemini"           # 项目名前缀
OUTPUT_DIR="gemini_keys"          # 密钥保存目录
KEY_FILE="all_keys.txt"           # 所有密钥汇总文件
ZIP_FILE="gemini_api_keys.zip"    # 下载包文件名
MAX_API_GEN_RETRY=5               # 密钥生成最大重试次数
API_GEN_WAIT=10                   # 密钥生成重试等待时间
PROJECT_CREATION_WAIT=20          # 项目创建后等待时间
MAX_PROJECT_ATTEMPTS=10           # 最大项目尝试次数

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
PURPLE="\033[1;35m"
RESET="\033[0m"

# ===== 函数：生成API密钥 =====
generate_gemini_key() {
  local project_id=$1
  local retry_count=0
  
  # 设置当前项目
  gcloud config set project $project_id --quiet 2>/dev/null
  
  while [ $retry_count -lt $MAX_API_GEN_RETRY ]; do
    echo -e "${YELLOW}  生成密钥尝试 ($((retry_count+1))/$MAX_API_GEN_RETRY)...${RESET}"
    
    # 尝试创建API密钥
    API_KEY_DATA=$(gcloud beta services api-keys create \
      --display-name="Gemini_Key" \
      --api-target=service=generativelanguage.googleapis.com \
      --format=json \
      --quiet 2>/dev/null)
    
    if [ -n "$API_KEY_DATA" ]; then
      # 提取密钥
      API_KEY=$(echo "$API_KEY_DATA" | jq -r '.[].keyString' 2>/dev/null)
      
      if [[ "$API_KEY" == AIzaSy* ]]; then
        echo -e "${GREEN}   ✓ API密钥生成成功${RESET}"
        echo "$API_KEY"
        return 0
      fi
    fi
    
    retry_count=$((retry_count+1))
    sleep $API_GEN_WAIT
  done
  
  echo -e "${RED}   ✗ API密钥生成失败${RESET}"
  return 1
}

# ===== 函数：启用必需API =====
enable_required_apis() {
  local project_id=$1
  
  echo -e "${YELLOW}  启用Generative Language API...${RESET}"
  
  # 尝试启用API
  gcloud services enable generativelanguage.googleapis.com --project=$project_id --quiet
  
  # 检查是否成功
  if [ $? -ne 0 ]; then
    echo -e "${YELLOW}  等待API状态传播...${RESET}"
    sleep 15
    gcloud services enable generativelanguage.googleapis.com --project=$project_id --quiet
  fi
  
  # 添加额外等待
  sleep 10
  echo -e "${GREEN}  ✓ API已启用${RESET}"
}

# ===== 函数：获取有效的结算账号 =====
get_valid_billing_account() {
  echo -e "${CYAN}正在获取结算账号...${RESET}"
  
  # 获取所有可用的结算账号
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" 2>/dev/null)
  
  if [ -z "$BILLING_ACCOUNTS" ]; then
    echo -e "${RED}未找到有效的结算账号！${RESET}"
    echo "可能原因："
    echo "1. 您没有结算账户权限"
    echo "2. 结算账户未激活"
    echo "3. 需要创建结算账户"
    echo "请访问: https://console.cloud.google.com/billing"
    exit 1
  fi
  
  # 显示所有结算账户
  echo -e "${GREEN}找到的结算账户：${RESET}"
  gcloud beta billing accounts list --format="table(ACCOUNT_ID, OPEN, NAME)"
  
  # 使用第一个激活的结算账户
  BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | head -1)
  echo -e "${GREEN}使用第一个结算账号: ${PURPLE}${BILLING_ACCOUNT}${RESET}"
  
  return 0
}

# ===== 函数：创建新项目 =====
create_new_project() {
  # 生成唯一项目ID (小写+数字)
  RANDOM_SUFFIX=$(date +%s | sha256sum | base64 | tr -dc 'a-z0-9' | head -c 6)
  PROJECT_ID="${PROJECT_PREFIX}-${RANDOM_SUFFIX}"
  
  echo -e "${CYAN}创建项目: ${BLUE}${PROJECT_ID}${RESET}"
  
  # 创建项目
  gcloud projects create ${PROJECT_ID} --name="Gemini-API" --quiet 2>/dev/null
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}项目创建失败！可能名称已被占用${RESET}"
    return 1
  fi
  
  echo $PROJECT_ID
  return 0
}

# ===== 函数：关联结算账户 =====
link_billing_account() {
  local project_id=$1
  local billing_account=$2
  local retry_count=0
  local max_retries=3
  
  echo -e "${YELLOW}  关联结算账户...${RESET}"
  
  while [ $retry_count -lt $max_retries ]; do
    # 尝试关联结算账户
    ERROR_OUTPUT=$(gcloud beta billing projects link ${project_id} \
      --billing-account=${billing_account} 2>&1)
    
    if [ $? -eq 0 ]; then
      # 添加等待确保状态传播
      sleep 15
      echo -e "${GREEN}  ✓ 结算账户关联成功${RESET}"
      return 0
    fi
    
    # 检查是否达到配额上限
    if [[ "$ERROR_OUTPUT" == *"quota"* ]] || [[ "$ERROR_OUTPUT" == *"limit"* ]]; then
      echo -e "${RED}   ✗ 已达结算账户项目配额上限！${RESET}"
      return 2
    fi
    
    retry_count=$((retry_count+1))
    echo -e "${YELLOW}  重试关联 ($retry_count/$max_retries)...${RESET}"
    sleep 10
  done
  
  echo -e "${RED}   ✗ 结算账户关联失败：${ERROR_OUTPUT}${RESET}"
  return 1
}

# ===== 函数：清理项目 =====
cleanup() {
  echo -e "\n${CYAN}清理临时文件...${RESET}"
  rm -rf "$OUTPUT_DIR" 2>/dev/null
  rm -f "$ZIP_FILE" 2>/dev/null
  rm -f "$KEY_FILE" 2>/dev/null
}

# ===== 函数：生成使用指南 =====
generate_usage_guide() {
  local key_file=$1
  local output_file="$OUTPUT_DIR/Gemini_API_使用指南.txt"
  
  cat > "$output_file" <<EOL
=============== Gemini API 使用指南 ===============

1. 密钥文件说明：
   - 每个项目对应一个API密钥
   - 文件名格式: gemini-<随机ID>_key.txt
   - 文件内容仅包含API密钥字符串

2. Python 使用示例：

import google.generativeai as genai

# 配置API密钥
API_KEY = "YOUR_API_KEY_HERE"  # 替换为实际密钥
genai.configure(api_key=API_KEY)

# 创建模型实例
model = genai.GenerativeModel('gemini-1.5-pro')

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
    
# 使用最新Gemini 2.5模型（当可用时）
# model = genai.GenerativeModel('gemini-2.5-pro')

3. 重要注意事项：
   - 每个密钥每月有100次免费调用
   - 超过免费额度后会产生费用
   - 定期轮换密钥：https://console.cloud.google.com/apis/credentials
   - 密钥管理：https://console.cloud.google.com/apis/credentials

4. 项目删除指南：
   如需删除项目以释放配额：
   1. 访问: https://console.cloud.google.com/cloud-resource-manager
   2. 选择要删除的项目
   3. 点击"删除项目"
   4. 输入项目ID确认删除

5. 官方文档：
   - Gemini API文档: https://ai.google.dev
   - Python SDK文档: https://ai.google.dev/api/python/google/generativeai
EOL
}

# ===== 主执行流程 =====
main() {
  # 检查是否在Cloud Shell中
  if [ -z "$CLOUD_SHELL" ]; then
    echo -e "${RED}错误：请在Google Cloud Shell中运行此脚本${RESET}"
    echo "访问：https://shell.cloud.google.com"
    exit 1
  fi
  
  echo -e "${PURPLE}"
  echo "======================================================"
  echo "               Gemini API 密钥工厂"
  echo "      批量创建项目并生成API密钥直到达到限额"
  echo "======================================================"
  echo -e "${RESET}"
  
  # 检查jq是否安装
  if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}安装jq JSON处理工具...${RESET}"
    sudo apt-get update -qq > /dev/null
    sudo apt-get install -y jq > /dev/null
    echo -e "${GREEN}✓ jq已安装${RESET}"
  fi
  
  # 清理旧文件
  cleanup
  
  # 创建输出目录
  mkdir -p "$OUTPUT_DIR"
  
  # 获取有效的结算账号
  get_valid_billing_account
  
  # 初始化计数器
  PROJECT_COUNT=0
  SUCCESS_COUNT=0
  KEY_FILE="$OUTPUT_DIR/$KEY_FILE"
  
  # 创建密钥汇总文件
  echo "# Gemini API Keys - Generated on $(date)" > "$KEY_FILE"
  echo "# Project ID, API Key" >> "$KEY_FILE"
  echo "========================================" >> "$KEY_FILE"
  
  echo -e "\n${CYAN}开始批量创建项目和API密钥...${RESET}"
  
  # 主循环 - 直到达到配额上限或最大尝试次数
  while [ $PROJECT_COUNT -lt $MAX_PROJECT_ATTEMPTS ]; do
    PROJECT_COUNT=$((PROJECT_COUNT+1))
    echo -e "\n${PURPLE}===== 处理项目 #${PROJECT_COUNT} =====${RESET}"
    
    # 创建新项目
    PROJECT_ID=$(create_new_project)
    if [ $? -ne 0 ]; then
      # 名称冲突时重试
      sleep 2
      continue
    fi
    
    # 关联结算账户
    link_billing_account $PROJECT_ID $BILLING_ACCOUNT
    link_result=$?
    
    if [ $link_result -eq 2 ]; then
      # 达到配额上限
      echo -e "${RED}已达结算账户项目配额上限！${RESET}"
      break
    elif [ $link_result -ne 0 ]; then
      # 其他错误，跳过此项目
      echo -e "${YELLOW}跳过此项目...${RESET}"
      continue
    fi
    
    # 设置当前项目
    gcloud config set project $PROJECT_ID --quiet
    
    # 启用API
    enable_required_apis $PROJECT_ID
    
    # 生成API密钥
    echo -e "${CYAN}  生成API密钥...${RESET}"
    API_KEY=$(generate_gemini_key $PROJECT_ID)
    
    if [ -z "$API_KEY" ]; then
      echo -e "${RED}  ✗ 跳过此项目${RESET}"
      continue
    fi
    
    # 保存密钥到单独文件
    KEY_FILE_NAME="${PROJECT_ID}_key.txt"
    echo "$API_KEY" > "$OUTPUT_DIR/$KEY_FILE_NAME"
    
    # 添加到密钥汇总
    echo "${PROJECT_ID}, ${API_KEY}" >> "$KEY_FILE"
    
    # 更新成功计数器
    SUCCESS_COUNT=$((SUCCESS_COUNT+1))
    
    echo -e "${GREEN}  ✓ 密钥保存到: ${KEY_FILE_NAME}${RESET}"
    
    # 项目间等待
    sleep $PROJECT_CREATION_WAIT
  done
  
  # 检查是否有成功生成密钥
  if [ $SUCCESS_COUNT -eq 0 ]; then
    echo -e "\n${RED}未生成任何API密钥！${RESET}"
    echo "可能原因："
    echo "1. 结算账户无效或未激活"
    echo "2. 结算账户已达到项目配额上限"
    echo "3. API服务启用失败"
    echo "4. 权限不足"
    echo "解决方案："
    echo "1. 检查结算账户状态：https://console.cloud.google.com/billing"
    echo "2. 检查项目配额：https://console.cloud.google.com/iam-admin/quotas"
    echo "3. 确保有创建API密钥的权限"
    exit 1
  fi
  
  # 生成使用指南
  generate_usage_guide "$KEY_FILE"
  
  # 创建ZIP压缩包
  echo -e "\n${CYAN}创建压缩包...${RESET}"
  zip -r "$ZIP_FILE" "$OUTPUT_DIR" > /dev/null
  
  # 打印结果
  echo -e "\n${GREEN}✅ 批量创建完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}尝试项目数:${RESET} ${PROJECT_COUNT}"
  echo -e "${BLUE}成功生成密钥:${RESET} ${SUCCESS_COUNT}"
  echo -e "${BLUE}结算账户:${RESET} ${BILLING_ACCOUNT}"
  echo -e "${BLUE}下载包:${RESET} ${ZIP_FILE}"
  echo "========================================"
  
  # 下载结果
  echo -e "\n${YELLOW}正在下载API密钥包...${RESET}"
  if cloudshell download "$ZIP_FILE"; then
    echo -e "${GREEN}✓ 下载已启动！${RESET}"
  else
    echo -e "${YELLOW}自动下载失败，请手动下载：${RESET}"
    echo "1. 在左侧文件浏览器中，找到当前目录"
    echo "2. 右键点击 '${ZIP_FILE}' 文件"
    echo "3. 选择 'Download'"
  fi
  
  # 显示包含的密钥
  echo -e "\n${CYAN}包含的API密钥：${RESET}"
  tail -n +4 "$KEY_FILE" | awk -F, '{print $1 ": " $2}'
  
  # 安全提示
  echo -e "\n${RED}⚠️ 重要提示：${RESET}"
  echo "1. 您已创建 ${SUCCESS_COUNT} 个项目"
  echo "2. 每个项目都会产生GCP资源"
  echo "3. 不需要时请删除项目以避免费用："
  echo "   https://console.cloud.google.com/cloud-resource-manager"
  echo "4. 定期轮换密钥：https://console.cloud.google.com/apis/credentials"
}

# 设置退出时清理
trap cleanup EXIT

# 执行主函数
main
