#!/bin/bash
# 文件名：gemini_quota_smart_setup.sh
# 功能：智能创建项目并生成Gemini API密钥，包含配额管理

# ======== 配置区 ========
DESIRED_PROJECTS=4                  # 期望创建的项目数量
PROJECT_PREFIX="gemini"             # 项目名前缀
OUTPUT_DIR="gemini_keys"            # 密钥保存目录
KEY_FILE="all_keys.txt"             # 所有密钥汇总文件
ZIP_FILE="gemini_api_keys.zip"      # 下载包文件名
MAX_RETRIES=3                       # 操作最大重试次数
REGION="us-central1"                # 默认区域
QUOTA_FILE="quota_status.txt"       # 配额状态文件

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PURPLE="\033[1;35m"
CYAN="\033[1;36m"
RESET="\033[0m"

# ===== 函数：显示横幅 =====
show_banner() {
  echo -e "${PURPLE}"
  echo "======================================================"
  echo "           Gemini API 密钥生成器 (智能配额版)"
  echo "         创建项目并生成API密钥"
  echo "         包含完整的配额管理解决方案"
  echo "======================================================"
  echo -e "${RESET}"
}

# ===== 函数：生成随机ID =====
generate_random_id() {
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8
}

# ===== 函数：获取有效的结算账号 =====
get_valid_billing_account() {
  echo -e "${CYAN}正在获取结算账号...${RESET}"
  
  # 获取所有可用的结算账号
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" 2>/dev/null)
  
  if [ -z "$BILLING_ACCOUNTS" ]; then
    echo -e "${RED}未找到有效的结算账号！${RESET}"
    echo "请访问: https://console.cloud.google.com/billing 创建结算账户"
    exit 1
  fi
  
  # 使用第一个结算账号
  BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | head -1)
  echo -e "${GREEN}✓ 使用结算账号: ${PURPLE}${BILLING_ACCOUNT}${RESET}"
  
  return 0
}

# ===== 函数：检查项目配额 =====
check_project_quota() {
  echo -e "${CYAN}正在检查项目配额...${RESET}"
  
  # 获取当前项目数
  CURRENT_PROJECTS=$(gcloud projects list --format="value(projectId)" | wc -l)
  
  # 尝试创建测试项目以获取配额信息
  TEST_PROJECT="test-project-$(date +%s)"
  ERROR_OUTPUT=$(gcloud projects create $TEST_PROJECT 2>&1)
  
  # 分析错误信息
  if [[ "$ERROR_OUTPUT" == *"quota"* ]] || [[ "$ERROR_OUTPUT" == *"exceeded"* ]]; then
    # 提取配额限制
    if [[ "$ERROR_OUTPUT" =~ [0-9]+ ]]; then
      QUOTA_LIMIT=${BASH_REMATCH[0]}
    else
      QUOTA_LIMIT="未知"
    fi
    
    echo -e "${RED}❌ 项目配额不足！${RESET}"
    echo -e "当前项目数: ${CURRENT_PROJECTS}"
    echo -e "配额限制: ${QUOTA_LIMIT}"
    
    # 保存配额状态
    echo "项目配额状态: 不足" > "$OUTPUT_DIR/$QUOTA_FILE"
    echo "当前项目数: $CURRENT_PROJECTS" >> "$OUTPUT_DIR/$QUOTA_FILE"
    echo "配额限制: $QUOTA_LIMIT" >> "$OUTPUT_DIR/$QUOTA_FILE"
    echo "检测时间: $(date)" >> "$OUTPUT_DIR/$QUOTA_FILE"
    
    return 1
  else
    # 删除测试项目
    gcloud projects delete $TEST_PROJECT --quiet 2>/dev/null
    
    echo -e "${GREEN}✓ 项目配额充足${RESET}"
    echo -e "当前项目数: ${CURRENT_PROJECTS}"
    
    # 保存配额状态
    echo "项目配额状态: 充足" > "$OUTPUT_DIR/$QUOTA_FILE"
    echo "当前项目数: $CURRENT_PROJECTS" >> "$OUTPUT_DIR/$QUOTA_FILE"
    echo "检测时间: $(date)" >> "$OUTPUT_DIR/$QUOTA_FILE"
    
    return 0
  fi
}

# ===== 函数：创建新项目 =====
create_new_project() {
  local project_id=$1
  local billing_account=$2
  
  echo -e "${YELLOW}创建项目: ${BLUE}${project_id}${RESET}"
  
  # 创建项目
  gcloud projects create ${project_id} --name="Gemini-Project" --quiet 2>/dev/null
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}项目创建失败！${RESET}"
    return 1
  fi
  
  # 关联结算账户
  echo -e "${YELLOW}关联结算账户...${RESET}"
  gcloud beta billing projects link ${project_id} \
    --billing-account=${billing_account} --quiet
    
  if [ $? -ne 0 ]; then
    echo -e "${RED}结算账户关联失败！${RESET}"
    return 1
  fi
  
  echo -e "${GREEN}✓ 项目创建并关联成功${RESET}"
  return 0
}

# ===== 函数：启用必需API =====
enable_required_apis() {
  local project_id=$1
  
  echo -e "${YELLOW}启用Generative Language API...${RESET}"
  
  # 尝试启用API
  gcloud services enable generativelanguage.googleapis.com --project=$project_id --quiet
  gcloud services enable aiplatform.googleapis.com --project=$project_id --quiet
  
  # 添加等待
  sleep 5
  echo -e "${GREEN}✓ API已启用${RESET}"
}

# ===== 函数：生成API密钥 =====
generate_gemini_key() {
  local project_id=$1
  
  echo -e "${YELLOW}生成API密钥...${RESET}"
  
  # 尝试创建API密钥
  API_KEY_DATA=$(gcloud beta services api-keys create \
    --display-name="Gemini_Key" \
    --api-target=service=generativelanguage.googleapis.com \
    --format=json \
    --quiet 2>/dev/null)
  
  if [ -z "$API_KEY_DATA" ]; then
    echo -e "${RED}API密钥生成失败${RESET}"
    return 1
  fi
  
  # 提取密钥
  API_KEY=$(echo "$API_KEY_DATA" | jq -r '.[].keyString' 2>/dev/null)
  
  if [[ "$API_KEY" != AIzaSy* ]]; then
    echo -e "${RED}无效的API密钥格式${RESET}"
    return 1
  fi
  
  echo -e "${GREEN}✓ API密钥生成成功${RESET}"
  echo "$API_KEY"
  return 0
}

# ===== 函数：生成配额解决方案指南 =====
generate_quota_solution_guide() {
  local output_file="$OUTPUT_DIR/配额解决方案指南.txt"
  
  cat > "$output_file" <<EOL
===================== 项目配额问题解决方案 =====================

您已达到Google Cloud项目配额上限。以下是详细的解决方案：

1. 查看当前配额使用情况：
   - 访问配额仪表板: https://console.cloud.google.com/iam-admin/quotas
   - 筛选 "Service: Cloud Resource Manager API"
   - 查看 "Projects" 配额使用情况

2. 释放配额空间：
   a) 删除不再使用的项目：
      - 访问项目管理: https://console.cloud.google.com/cloud-resource-manager
      - 选择不再需要的项目
      - 点击"删除"并确认
   
   b) 注意：删除项目需要7-30天才能释放配额

3. 请求增加配额：
   a) 访问配额仪表板: https://console.cloud.google.com/iam-admin/quotas
   b) 选择 "Projects" 配额
   c) 点击"申请增加配额"
   d) 填写申请表：
      - 请求的配额限制: 建议增加5-10个项目
      - 理由: "需要创建新项目以支持Gemini API开发"
   e) 提交申请，通常1-2个工作日内处理

4. 替代方案：
   a) 使用现有项目生成API密钥：
      - 在现有项目中启用Generative Language API
      - 使用命令: gcloud services enable generativelanguage.googleapis.com
      - 生成API密钥: gcloud beta services api-keys create --api-target=service=generativelanguage.googleapis.com
   
   b) 使用多个结算账户：
      - 创建新的结算账户: https://console.cloud.google.com/billing
      - 每个结算账户有独立项目配额

5. 最佳实践：
   - 定期清理未使用的项目
   - 使用项目命名规范便于管理
   - 使用文件夹组织项目: https://console.cloud.google.com/cloud-resource-manager

6. 官方文档参考：
   - 管理项目配额: https://cloud.google.com/resource-manager/docs/creating-project#quota
   - 配额错误排查: https://cloud.google.com/resource-manager/docs/troubleshooting#quota

================================================================
EOL
}

# ===== 函数：生成使用指南 =====
generate_usage_guide() {
  local output_file="$OUTPUT_DIR/使用说明.txt"
  local success_count=$1
  
  cat > "$output_file" <<EOL
=============== Gemini API 使用指南 ===============

包含的API密钥数量: $success_count

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
4. 配额解决方案见: 配额解决方案指南.txt
EOL
}

# ===== 主执行流程 =====
main() {
  # 创建输出目录
  mkdir -p "$OUTPUT_DIR"
  
  # 显示横幅
  show_banner
  
  # 检查jq是否安装
  if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}安装jq JSON处理工具...${RESET}"
    sudo apt-get update -qq > /dev/null
    sudo apt-get install -y jq > /dev/null
    echo -e "${GREEN}✓ jq已安装${RESET}"
  fi
  
  # 获取有效的结算账号
  get_valid_billing_account
  
  # 检查项目配额
  if ! check_project_quota; then
    echo -e "${RED}无法创建新项目，已达配额上限！${RESET}"
    
    # 生成配额解决方案指南
    generate_quota_solution_guide
    
    # 创建ZIP压缩包
    zip -r "$ZIP_FILE" "$OUTPUT_DIR" > /dev/null
    
    # 下载结果
    echo -e "\n${YELLOW}正在下载配额解决方案指南...${RESET}"
    if cloudshell download "$ZIP_FILE"; then
      echo -e "${GREEN}✓ 下载已启动！${RESET}"
    else
      echo -e "${YELLOW}自动下载失败，请手动下载：${RESET}"
      echo "1. 在左侧文件浏览器中，找到当前目录"
      echo "2. 右键点击 '${ZIP_FILE}' 文件"
      echo "3. 选择 'Download'"
    fi
    
    exit 1
  fi
  
  # 初始化密钥文件
  KEY_FILE_PATH="$OUTPUT_DIR/$KEY_FILE"
  echo "# Gemini API Keys - Generated on $(date)" > "$KEY_FILE_PATH"
  echo "# Project ID, API Key" >> "$KEY_FILE_PATH"
  echo "========================================" >> "$KEY_FILE_PATH"
  
  # 创建项目计数器
  SUCCESS_COUNT=0
  
  # 计算可创建的项目数
  AVAILABLE_PROJECTS=$((DESIRED_PROJECTS))
  echo -e "${GREEN}可创建项目数: ${AVAILABLE_PROJECTS}${RESET}"
  
  # 创建项目
  for i in $(seq 1 $AVAILABLE_PROJECTS); do
    echo -e "\n${CYAN}===== 创建项目 #${i} =====${RESET}"
    
    # 生成唯一项目ID
    RANDOM_SUFFIX=$(generate_random_id)
    PROJECT_ID="${PROJECT_PREFIX}-${RANDOM_SUFFIX}"
    
    # 创建项目并关联结算
    if create_new_project $PROJECT_ID $BILLING_ACCOUNT; then
      # 启用API
      enable_required_apis $PROJECT_ID
      
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
        
        echo -e "${GREEN}✓ 密钥保存到: ${KEY_FILE_NAME}${RESET}"
      fi
    fi
    
    # 项目间等待
    sleep 5
  done
  
  # 生成使用指南
  generate_usage_guide $SUCCESS_COUNT
  
  # 创建ZIP压缩包
  echo -e "\n${CYAN}创建压缩包...${RESET}"
  zip -r "$ZIP_FILE" "$OUTPUT_DIR" > /dev/null
  
  # 打印结果
  echo -e "\n${GREEN}✅ 密钥生成完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}尝试创建项目数:${RESET} ${AVAILABLE_PROJECTS}"
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
  
  # 安全提示
  echo -e "\n${RED}⚠️ 重要提示：${RESET}"
  echo "1. 您已创建 ${SUCCESS_COUNT} 个项目"
  echo "2. 每个项目都会产生GCP资源"
  echo "3. 不需要时请删除项目以避免费用："
  echo "   https://console.cloud.google.com/cloud-resource-manager"
  
  # 如果创建数量不足，提供解决方案
  if [ $SUCCESS_COUNT -lt $DESIRED_PROJECTS ]; then
    echo -e "\n${YELLOW}注意：未达到期望创建数量${RESET}"
    echo -e "请下载并查看 '配额解决方案指南.txt' 文件获取解决方案"
  fi
}

# 执行主函数
main
