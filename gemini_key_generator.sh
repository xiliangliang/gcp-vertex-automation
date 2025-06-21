#!/bin/bash
# 文件名：gemini_4keys_diagnostic.sh
# 功能：创建4个可结算项目并生成Gemini API密钥，包含完整诊断功能

# ======== 配置区 ========
NUM_PROJECTS=4                     # 要创建的项目数量
PROJECT_PREFIX="gemini"            # 项目名前缀
OUTPUT_DIR="gemini_keys"           # 密钥保存目录
KEY_FILE="all_keys.txt"            # 所有密钥汇总文件
ZIP_FILE="gemini_api_keys.zip"     # 下载包文件名
MAX_RETRIES=3                      # 操作最大重试次数
REGION="us-central1"               # 默认区域
DIAGNOSTIC_FILE="diagnostic.log"   # 诊断日志文件

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PURPLE="\033[1;35m"
CYAN="\033[1;36m"
RESET="\033[0m"

# ===== 函数：记录诊断信息 =====
log_diagnostic() {
  local message=$1
  local level=${2:-INFO}
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  
  echo -e "${timestamp} [${level}] ${message}" >> "$OUTPUT_DIR/$DIAGNOSTIC_FILE"
  
  # 根据日志级别输出不同颜色
  case $level in
    ERROR)
      echo -e "${RED}${message}${RESET}"
      ;;
    WARN)
      echo -e "${YELLOW}${message}${RESET}"
      ;;
    SUCCESS)
      echo -e "${GREEN}${message}${RESET}"
      ;;
    *)
      echo -e "${CYAN}${message}${RESET}"
      ;;
  esac
}

# ===== 函数：生成随机ID =====
generate_random_id() {
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6
}

# ===== 函数：环境预检 =====
preflight_check() {
  log_diagnostic "开始环境预检..."
  
  # 1. 检查是否在Cloud Shell中
  if [ -z "$CLOUD_SHELL" ]; then
    log_diagnostic "错误：请在Google Cloud Shell中运行此脚本" "ERROR"
    log_diagnostic "访问：https://shell.cloud.google.com" "ERROR"
    exit 1
  fi
  log_diagnostic "✓ 检测到Cloud Shell环境" "SUCCESS"
  
  # 2. 检查jq是否安装
  if ! command -v jq &> /dev/null; then
    log_diagnostic "安装jq JSON处理工具..." "WARN"
    sudo apt-get update -qq > /dev/null
    sudo apt-get install -y jq > /dev/null
    log_diagnostic "✓ jq已安装" "SUCCESS"
  else
    log_diagnostic "✓ jq已安装" "SUCCESS"
  fi
  
  # 3. 检查gcloud认证
  if ! gcloud auth list --format="value(account)" | grep -q '@'; then
    log_diagnostic "错误：未检测到gcloud认证" "ERROR"
    log_diagnostic "请运行: gcloud auth login" "ERROR"
    exit 1
  fi
  log_diagnostic "✓ gcloud已认证" "SUCCESS"
  
  # 4. 检查项目创建权限
  if ! gcloud projects create test-project-$(date +%s) --name="Test-Project" --quiet 2>&1 | grep -q "PERMISSION_DENIED"; then
    log_diagnostic "✓ 有项目创建权限" "SUCCESS"
  else
    log_diagnostic "错误：缺少项目创建权限" "ERROR"
    log_diagnostic "需要权限：resourcemanager.projects.create" "ERROR"
    exit 1
  fi
  
  # 5. 检查结算账户访问权限
  if ! gcloud beta billing accounts list --quiet >/dev/null 2>&1; then
    log_diagnostic "错误：缺少结算账户访问权限" "ERROR"
    log_diagnostic "需要权限：billing.accounts.list" "ERROR"
    exit 1
  fi
  log_diagnostic "✓ 有结算账户访问权限" "SUCCESS"
  
  # 6. 检查API密钥创建权限
  if ! gcloud beta services api-keys create --display-name="Test_Key" --api-target=service=generativelanguage.googleapis.com --quiet 2>&1 | grep -q "PERMISSION_DENIED"; then
    log_diagnostic "✓ 有API密钥创建权限" "SUCCESS"
  else
    log_diagnostic "警告：可能缺少API密钥创建权限" "WARN"
    log_diagnostic "需要权限：serviceusage.apiKeys.create" "WARN"
  fi
}

# ===== 函数：获取有效的结算账号 =====
get_valid_billing_account() {
  log_diagnostic "正在获取结算账号..."
  
  # 获取所有可用的结算账号
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" 2>/dev/null)
  
  if [ -z "$BILLING_ACCOUNTS" ]; then
    log_diagnostic "未找到有效的结算账号！" "ERROR"
    log_diagnostic "可能原因：" "ERROR"
    log_diagnostic "1. 您没有结算账户权限" "ERROR"
    log_diagnostic "2. 结算账户未激活" "ERROR"
    log_diagnostic "3. 需要创建结算账户" "ERROR"
    log_diagnostic "请访问: https://console.cloud.google.com/billing" "ERROR"
    exit 1
  fi
  
  # 使用第一个结算账号
  BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | head -1)
  log_diagnostic "✓ 使用结算账号: ${BILLING_ACCOUNT}" "SUCCESS"
  
  # 检查结算账户状态
  ACCOUNT_STATUS=$(gcloud beta billing accounts describe $BILLING_ACCOUNT --format="value(open)" 2>/dev/null)
  if [ "$ACCOUNT_STATUS" != "True" ]; then
    log_diagnostic "警告：结算账户未激活！" "WARN"
    log_diagnostic "请激活结算账户: https://console.cloud.google.com/billing/${BILLING_ACCOUNT}" "WARN"
  fi
  
  return 0
}

# ===== 函数：创建新项目 =====
create_new_project() {
  local project_id=$1
  local billing_account=$2
  local retry_count=0
  local error_msg=""
  
  while [ $retry_count -lt $MAX_RETRIES ]; do
    log_diagnostic "创建项目: ${project_id}"
    
    # 创建项目
    ERROR_OUTPUT=$(gcloud projects create ${project_id} --name="Gemini-Project" 2>&1)
    
    if [ $? -eq 0 ]; then
      log_diagnostic "✓ 项目创建成功" "SUCCESS"
      
      # 关联结算账户
      log_diagnostic "关联结算账户..."
      ERROR_OUTPUT=$(gcloud beta billing projects link ${project_id} \
        --billing-account=${billing_account} 2>&1)
        
      if [ $? -eq 0 ]; then
        log_diagnostic "✓ 结算账户关联成功" "SUCCESS"
        return 0
      else
        error_msg="结算账户关联失败: ${ERROR_OUTPUT}"
      fi
    else
      error_msg="项目创建失败: ${ERROR_OUTPUT}"
    fi
    
    retry_count=$((retry_count+1))
    log_diagnostic "尝试失败，重试中 ($retry_count/$MAX_RETRIES)..." "WARN"
    sleep 5
  done
  
  log_diagnostic "❌ 创建项目失败: ${error_msg}" "ERROR"
  return 1
}

# ===== 函数：启用必需API =====
enable_required_apis() {
  local project_id=$1
  
  log_diagnostic "启用Generative Language API..."
  
  # 尝试启用API
  ERROR_OUTPUT=$(gcloud services enable generativelanguage.googleapis.com --project=$project_id 2>&1)
  
  if [ $? -ne 0 ]; then
    log_diagnostic "API启用失败: ${ERROR_OUTPUT}" "ERROR"
    return 1
  fi
  
  log_diagnostic "✓ API已启用" "SUCCESS"
  return 0
}

# ===== 函数：生成API密钥 =====
generate_gemini_key() {
  local project_id=$1
  local retry_count=0
  local error_msg=""
  
  # 设置当前项目
  gcloud config set project $project_id --quiet 2>/dev/null
  
  while [ $retry_count -lt $MAX_RETRIES ]; do
    log_diagnostic "生成API密钥..."
    
    # 尝试创建API密钥
    API_KEY_DATA=$(gcloud beta services api-keys create \
      --display-name="Gemini_Key" \
      --api-target=service=generativelanguage.googleapis.com \
      --format=json 2>&1)
    
    if [[ "$API_KEY_DATA" == *"keyString"* ]]; then
      # 提取密钥
      API_KEY=$(echo "$API_KEY_DATA" | jq -r '.[].keyString' 2>/dev/null)
      
      if [[ "$API_KEY" == AIzaSy* ]]; then
        log_diagnostic "✓ API密钥生成成功" "SUCCESS"
        echo "$API_KEY"
        return 0
      else
        error_msg="无效的API密钥格式: ${API_KEY}"
      fi
    else
      error_msg="API密钥创建失败: ${API_KEY_DATA}"
    fi
    
    retry_count=$((retry_count+1))
    log_diagnostic "密钥生成失败，重试中 ($retry_count/$MAX_RETRIES)..." "WARN"
    sleep 5
  done
  
  log_diagnostic "❌ API密钥生成失败: ${error_msg}" "ERROR"
  return 1
}

# ===== 函数：生成故障排除指南 =====
generate_troubleshooting_guide() {
  local output_file="$OUTPUT_DIR/故障排除指南.txt"
  
  cat > "$output_file" <<EOL
==================== Gemini API 密钥生成故障排除指南 ====================

1. 常见错误及解决方案：

[错误] 项目创建失败：配额不足
  解决方案：
  - 检查项目配额: https://console.cloud.google.com/iam-admin/quotas
  - 删除旧项目: https://console.cloud.google.com/cloud-resource-manager
  - 请求增加配额: https://support.google.com/cloud/answer/6330231

[错误] 结算账户关联失败
  解决方案：
  - 验证结算账户状态: https://console.cloud.google.com/billing
  - 检查账户是否有效: https://console.cloud.google.com/billing/${BILLING_ACCOUNT}
  - 确保账户未达到项目限额

[错误] API启用失败
  解决方案：
  - 手动启用API: https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com
  - 检查服务使用权限: https://console.cloud.google.com/iam-admin/serviceusage

[错误] API密钥生成失败
  解决方案：
  - 检查API密钥配额: https://console.cloud.google.com/apis/credentials/quotas
  - 验证项目结算状态: https://console.cloud.google.com/billing/linkedaccount
  - 手动创建API密钥: https://console.cloud.google.com/apis/credentials

2. 权限检查清单：

□ 项目创建权限 (resourcemanager.projects.create)
□ 结算账户访问权限 (billing.accounts.list)
□ 结算账户关联权限 (billing.resourceAssociations.create)
□ API启用权限 (serviceusage.services.enable)
□ API密钥创建权限 (serviceusage.apiKeys.create)

3. 关键链接：

- 项目仪表板: https://console.cloud.google.com/home/dashboard
- 结算账户管理: https://console.cloud.google.com/billing
- 服务配额管理: https://console.cloud.google.com/iam-admin/quotas
- API和服务: https://console.cloud.google.com/apis/dashboard
- API密钥管理: https://console.cloud.google.com/apis/credentials

4. 诊断日志位置：
   - $OUTPUT_DIR/$DIAGNOSTIC_FILE

5. 重新运行脚本：
   在解决问题后，可以重新运行脚本：
   $ ./$(basename $0)

=======================================================================
EOL
}

# ===== 主执行流程 =====
main() {
  # 创建输出目录
  mkdir -p "$OUTPUT_DIR"
  > "$OUTPUT_DIR/$DIAGNOSTIC_FILE"  # 清空日志文件
  
  echo -e "${PURPLE}"
  echo "======================================================"
  echo "              Gemini API 密钥生成器 (诊断版)"
  echo "           创建4个项目并生成API密钥"
  echo "         包含完整诊断和故障排除指南"
  echo "======================================================"
  echo -e "${RESET}"
  
  # 执行预检
  preflight_check
  
  # 获取有效的结算账号
  get_valid_billing_account
  
  # 初始化密钥文件
  KEY_FILE_PATH="$OUTPUT_DIR/$KEY_FILE"
  echo "# Gemini API Keys - Generated on $(date)" > "$KEY_FILE_PATH"
  echo "# Project ID, API Key" >> "$KEY_FILE_PATH"
  echo "========================================" >> "$KEY_FILE_PATH"
  
  # 创建项目计数器
  SUCCESS_COUNT=0
  
  # 创建4个项目
  for i in $(seq 1 $NUM_PROJECTS); do
    log_diagnostic "\n===== 创建项目 #${i} =====" "HEADER"
    
    # 生成唯一项目ID
    RANDOM_SUFFIX=$(generate_random_id)
    PROJECT_ID="${PROJECT_PREFIX}-${RANDOM_SUFFIX}"
    
    # 创建项目并关联结算
    if create_new_project $PROJECT_ID $BILLING_ACCOUNT; then
      # 启用API
      if enable_required_apis $PROJECT_ID; then
        # 生成API密钥
        API_KEY=$(generate_gemini_key $PROJECT_ID)
        
        if [ -n "$API_KEY" ]; then
          # 保存密钥到单独文件
          KEY_FILE_NAME="${PROJECT_ID}_key.txt"
          echo "$API_KEY" > "$OUTPUT_DIR/$KEY_FILE_NAME"
          
          # 添加到密钥汇总
          echo "${PROJECT_ID}, ${API_KEY}" >> "$KEY_FILE_PATH"
          
          # 更新成功计数器
          SUCCESS_COUNT=$((SUCCESS_COUNT+1))
          
          log_diagnostic "✓ 密钥保存到: ${KEY_FILE_NAME}" "SUCCESS"
        fi
      fi
    fi
    
    # 项目间等待
    sleep 10
  done
  
  # 生成故障排除指南
  generate_troubleshooting_guide
  
  # 创建使用说明
  USAGE_FILE="$OUTPUT_DIR/使用说明.txt"
  cat > "$USAGE_FILE" <<EOL
=============== Gemini API 使用指南 ===============

包含的API密钥数量: $SUCCESS_COUNT

每个密钥文件对应一个项目：
  - 文件名格式: gemini-<随机ID>_key.txt
  - 文件内容仅包含API密钥字符串

Python 使用示例：

import google.generativeai as genai

# 从文件读取API密钥
with open("gemini-xxxxxx_key.txt") as f:
    API_KEY = f.read().strip()

genai.configure(api_key=API_KEY)

# 使用Gemini Pro模型
model = genai.GenerativeModel('gemini-pro')

# 生成内容
response = model.generate_content("请解释量子计算的基本原理")
print(response.text)

重要提示：
1. 每个密钥每月有100次免费调用
2. 超过免费额度后会产生费用
3. 不需要时请删除项目：https://console.cloud.google.com/cloud-resource-manager
4. 故障排除指南见: 故障排除指南.txt
EOL
  
  # 创建ZIP压缩包
  log_diagnostic "创建压缩包..."
  zip -r "$ZIP_FILE" "$OUTPUT_DIR" > /dev/null
  
  # 打印结果
  echo -e "\n${GREEN}✅ 密钥生成完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}创建项目数:${RESET} ${NUM_PROJECTS}"
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
  
  # 诊断总结
  if [ $SUCCESS_COUNT -lt $NUM_PROJECTS ]; then
    echo -e "\n${RED}⚠️ 部分项目创建失败！${RESET}"
    echo -e "请查看诊断日志: ${OUTPUT_DIR}/${DIAGNOSTIC_FILE}"
    echo -e "完整故障排除指南已包含在ZIP包中"
  fi
  
  # 安全提示
  echo -e "\n${RED}⚠️ 重要提示：${RESET}"
  echo "1. 您已创建 ${SUCCESS_COUNT} 个项目"
  echo "2. 每个项目都会产生GCP资源"
  echo "3. 不需要时请删除项目以避免费用："
  echo "   https://console.cloud.google.com/cloud-resource-manager"
  echo "4. 故障排除指南已包含在ZIP包中"
}

# 执行主函数
main
