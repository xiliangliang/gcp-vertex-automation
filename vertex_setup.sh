#!/bin/bash
# 文件名：vertex_setup_interactive.sh
# 功能：交互式创建或检查Vertex AI项目，并生成配置文件

# ======== 配置区 ========
PROJECT_PREFIX="vertex-api"                 # 新项目名的前缀
DEFAULT_REGION="us-central1"                # 默认区域
SERVICE_ACCOUNT_NAME="vertex-automation"    # 服务账号名称
CONFIG_FILE_NAME="vertex-config.json"       # 配置文件名称
KEY_FILE_NAME="vertex-key.json"             # 服务账号密钥文件名
MAX_PROJECTS=10                             # 最大允许创建的项目数

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ==============================================================================
#
#  核心函数库 (Core Functions)
#
# ==============================================================================

# ===== 函数：生成随机ID =====
generate_random_id() {
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6
}

# ===== 函数：获取结算账号ID =====
get_billing_account() {
  echo -e "${YELLOW}正在获取可用的结算账号...${RESET}"
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" 2>/dev/null)
  if [ -z "$BILLING_ACCOUNTS" ]; then
    echo -e "${RED}错误：未找到任何有效的结算账号！${RESET}"
    return 1
  fi
  # 默认使用第一个结算账号
  BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | awk '{print $1}')
  echo -e "${GREEN}✓ 将使用结算账号: ${BLUE}${BILLING_ACCOUNT}${RESET}"
  return 0
}

# ===== 函数：检查并关联结算 =====
link_and_verify_billing() {
  local project_id=$1
  local billing_account=$2
  local max_retries=8
  local wait_seconds=15

  echo -e "${YELLOW}步骤A: 检查并关联项目结算...${RESET}"
  
  # 检查当前结算状态
  billing_status=$(gcloud beta billing projects describe "$project_id" --format="value(billingEnabled)" 2>/dev/null)
  if [ "$billing_status" = "True" ]; then
    echo -e "${GREEN}✓ 项目 '${project_id}' 的结算已启用。${RESET}"
    return 0
  fi

  echo -e "${YELLOW}项目结算未启用，正在尝试关联结算账号: ${BLUE}${billing_account}${RESET}"
  gcloud beta billing projects link "$project_id" --billing-account="$billing_account"
  if [ $? -ne 0 ]; then
    echo -e "${RED}错误：关联结算账号失败！请检查权限或配额。${RESET}"
    return 1
  fi

  echo -e "${YELLOW}等待结算状态生效...${RESET}"
  for ((i=1; i<=max_retries; i++)); do
    billing_status=$(gcloud beta billing projects describe "$project_id" --format="value(billingEnabled)" 2>/dev/null)
    if [ "$billing_status" = "True" ]; then
      echo -e "${GREEN}✓ 结算已成功启用！${RESET}"
      sleep 10 # 额外等待，确保状态传播
      return 0
    fi
    echo -e "${YELLOW}等待中 ($i/$max_retries)...${RESET}"
    sleep $wait_seconds
  done

  echo -e "${RED}错误：在超时后结算仍未启用。${RESET}"
  echo "请手动访问以下链接检查：https://console.cloud.google.com/billing/linkedaccount?project=${project_id}"
  return 1
}

# ===== 函数：启用所有必需的API =====
ensure_apis_enabled() {
  local project_id=$1
  echo -e "${YELLOW}步骤B: 检查并启用必需的API服务...${RESET}"
  APIS=(
    "aiplatform.googleapis.com"
    "generativelanguage.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "serviceusage.googleapis.com"
    "iam.googleapis.com"
    "apikeys.googleapis.com"
  )
  
  for api in "${APIS[@]}"; do
    # gcloud services enable 是幂等的，如果已启用，它会直接成功
    if gcloud services enable "${api}" --project="$project_id" --quiet; then
      echo -e " - ${GREEN}✓ ${api}${RESET}"
    else
      echo -e " - ${RED}✗ 启用 ${api} 失败！${RESET}"
      # 增加一次重试
      sleep 10
      if ! gcloud services enable "${api}" --project="$project_id" --quiet; then
         echo -e "${RED}错误：重试启用 ${api} 仍然失败。请检查项目权限。${RESET}"
         return 1
      fi
      echo -e " - ${GREEN}✓ ${api} (重试成功)${RESET}"
    fi
  done
  
  echo -e "${GREEN}✓ 所有API均已启用。${RESET}"
  echo -e "${YELLOW}等待API服务完全生效（30秒）...${RESET}"
  sleep 30
  return 0
}

# ===== 函数：创建服务账号并分配角色 =====
ensure_service_account_and_roles() {
  local project_id=$1
  local sa_name=$2
  local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"

  echo -e "${YELLOW}步骤C: 检查并配置服务账号及权限...${RESET}"

  # 检查服务账号是否存在，不存在则创建
  if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" --quiet &>/dev/null; then
    echo " - 服务账号不存在，正在创建: ${BLUE}${sa_email}${RESET}"
    gcloud iam service-accounts create "$sa_name" \
      --display-name="Vertex AI Automation" \
      --project="$project_id"
  else
    echo -e " - ${GREEN}✓ 服务账号已存在: ${BLUE}${sa_email}${RESET}"
  fi

  # 分配角色（add-iam-policy-binding是幂等的）
  echo " - 分配 'Vertex AI User' 角色..."
  gcloud projects add-iam-policy-binding "$project_id" \
    --member="serviceAccount:${sa_email}" \
    --role="roles/aiplatform.user" \
    --quiet

  echo " - 分配 'Service Account User' 角色..."
  gcloud projects add-iam-policy-binding "$project_id" \
    --member="serviceAccount:${sa_email}" \
    --role="roles/iam.serviceAccountUser" \
    --quiet

  echo -e "${GREEN}✓ 服务账号和权限配置完成。${RESET}"
  return 0
}

# ===== 函数：生成API密钥和配置文件 =====
generate_and_output_config() {
  local project_id=$1
  local sa_name=$2
  local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"
  local max_retries=5
  local wait_seconds=12

  echo -e "${YELLOW}步骤D: 生成API密钥、服务账号密钥和配置文件...${RESET}"

  # 1. 生成API密钥
  echo " - 正在生成API密钥..." >&2
  local api_key=""
  for ((i=1; i<=max_retries; i++)); do
    api_key=$(gcloud api-keys create \
      --display-name="Vertex_Auto_Key" \
      --project="$project_id" \
      --format="value(keyString)" 2>/dev/null)
    if [[ "$api_key" == AIzaSy* ]]; then
      echo -e "   ${GREEN}✓ API密钥生成成功。${RESET}" >&2
      break
    fi
    api_key="" # Reset on failure
    echo -e "   ${YELLOW}密钥生成失败 ($i/$max_retries)，重试中...${RESET}" >&2
    sleep $wait_seconds
  done

  if [ -z "$api_key" ]; then
    echo -e "${RED}错误：最终无法生成API密钥。脚本终止。${RESET}" >&2
    return 1
  fi

  # 2. 生成服务账号密钥文件
  echo " - 正在生成服务账号密钥文件: ${BLUE}${KEY_FILE_NAME}${RESET}"
  rm -f "$KEY_FILE_NAME" 2>/dev/null
  gcloud iam service-accounts keys create "$KEY_FILE_NAME" \
    --iam-account="$sa_email" \
    --project="$project_id"

  # 3. 创建最终的配置文件
  echo " - 正在创建配置文件: ${BLUE}${CONFIG_FILE_NAME}${RESET}"
  rm -f "$CONFIG_FILE_NAME" 2>/dev/null
  cat > "$CONFIG_FILE_NAME" <<EOL
{
  "project_id": "${project_id}",
  "region": "${DEFAULT_REGION}",
  "service_account_email": "${sa_email}",
  "api_key": "${api_key}",
  "key_file": "${KEY_FILE_NAME}",
  "timestamp": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
EOL

  # 4. 打印结果和下载
  echo -e "\n${GREEN}✅ 所有配置已完成！${RESET}"
  echo "========================================"
  echo -e "${BLUE}项目ID:${RESET} ${project_id}"
  echo -e "${BLUE}API密钥:${RESET} ${api_key}"
  echo -e "${BLUE}配置文件:${RESET} ${CONFIG_FILE_NAME}"
  echo -e "${BLUE}密钥文件:${RESET} ${KEY_FILE_NAME}"
  echo "========================================"
  echo -e "\n${YELLOW}配置文件内容：${RESET}"
  cat "$CONFIG_FILE_NAME" | jq .

  echo -e "\n${YELLOW}正在尝试自动下载配置文件...${RESET}"
  if cloudshell download "$CONFIG_FILE_NAME" && cloudshell download "$KEY_FILE_NAME"; then
    echo -e "${GREEN}✓ 配置文件和密钥文件下载已启动！${RESET}"
  else
    echo -e "${YELLOW}自动下载失败，请在左侧文件浏览器中手动下载 '${CONFIG_FILE_NAME}' 和 '${KEY_FILE_NAME}'。${RESET}"
  fi
}


# ==============================================================================
#
#  功能实现 (Feature Implementations)
#
# ==============================================================================

# ===== 功能1：创建新项目 =====
create_new_project() {
  echo -e "\n${BLUE}--- 开始执行：创建新Vertex AI项目 ---${RESET}"
  
  # 检查项目配额
  local current_projects=$(gcloud projects list --format="value(projectId)" | wc -l)
  if [ "$current_projects" -ge "$MAX_PROJECTS" ]; then
    echo -e "${RED}错误：已达到项目配额上限 ($MAX_PROJECTS个项目)。${RESET}"
    return
  fi
  echo -e "${GREEN}✓ 项目配额检查通过 ($current_projects/$MAX_PROJECTS)。${RESET}"

  # 获取结算账号
  if ! get_billing_account; then return; fi
  local billing_account=$BILLING_ACCOUNT

  # 创建项目
  local random_suffix=$(generate_random_id)
  local project_id="${PROJECT_PREFIX}-${random_suffix}"
  echo -e "${YELLOW}正在创建新项目 [${BLUE}${project_id}${YELLOW}]...${RESET}"
  if ! gcloud projects create "$project_id" --name="Vertex-AI-API"; then
    echo -e "${RED}错误：项目创建失败！可能是ID冲突，请重试。${RESET}"
    return
  fi
  gcloud config set project "$project_id"

  # 执行后续所有步骤
  if ! link_and_verify_billing "$project_id" "$billing_account"; then return; fi
  if ! ensure_apis_enabled "$project_id"; then return; fi
  if ! ensure_service_account_and_roles "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  if ! generate_and_output_config "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  
  echo -e "\n${GREEN}--- 新项目创建流程全部完成 ---${RESET}"
}

# ===== 功能2：检查现有项目 =====
check_existing_project() {
  echo -e "\n${BLUE}--- 开始执行：检查现有Vertex AI项目 ---${RESET}"
  
  read -p "请输入您要检查的GCP项目ID: " project_id
  if [ -z "$project_id" ]; then
    echo -e "${RED}错误：项目ID不能为空。${RESET}"
    return
  fi

  # 验证项目是否存在
  echo -e "${YELLOW}正在验证项目 '${project_id}'...${RESET}"
  if ! gcloud projects describe "$project_id" &>/dev/null; then
    echo -e "${RED}错误：项目 '${project_id}' 不存在或您没有权限访问。${RESET}"
    return
  fi
  echo -e "${GREEN}✓ 项目存在，开始检查配置...${RESET}"
  gcloud config set project "$project_id"

  # 获取结算账号
  if ! get_billing_account; then return; fi
  local billing_account=$BILLING_ACCOUNT

  # 执行所有检查和配置步骤
  if ! link_and_verify_billing "$project_id" "$billing_account"; then return; fi
  if ! ensure_apis_enabled "$project_id"; then return; fi
  if ! ensure_service_account_and_roles "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  if ! generate_and_output_config "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi

  echo -e "\n${GREEN}--- 现有项目检查和配置流程全部完成 ---${RESET}"
}


# ==============================================================================
#
#  主执行流程 (Main Execution)
#
# ==============================================================================
main() {
  # 环境检查
  if [ -z "$CLOUD_SHELL" ]; then
    echo -e "${RED}错误：请在Google Cloud Shell中运行此脚本。${RESET}"
    exit 1
  fi
  if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}正在安装jq JSON处理工具...${RESET}"
    sudo apt-get update -qq > /dev/null && sudo apt-get install -y jq > /dev/null
  fi

  while true; do
    clear
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${GREEN}  Vertex AI 项目自动化配置工具 v2.0${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "\n请选择您要执行的操作：\n"
    echo -e "  ${YELLOW}1)${RESET} 创建一个全新的Vertex AI项目并生成配置"
    echo -e "  ${YELLOW}2)${RESET} 检查/修复一个已有的项目并生成配置"
    echo -e "  ${YELLOW}3)${RESET} 退出脚本\n"
    read -p "请输入选项 [1, 2, 3]: " choice

    case $choice in
      1)
        create_new_project
        ;;
      2)
        check_existing_project
        ;;
      3)
        echo -e "\n${BLUE}再见！${RESET}"
        exit 0
        ;;
      *)
        echo -e "\n${RED}无效的选项，请输入 1, 2, 或 3。${RESET}"
        ;;
    esac
    
    echo -e "\n"
    read -p "按 Enter 键返回主菜单..."
  done
}

# 执行主函数
main
