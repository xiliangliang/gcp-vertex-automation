#!/bin/bash
# 文件名：vertex_setup_interactive_v3.7.sh
# 功能：交互式创建或配置Vertex AI项目 (已修正API密钥捕获逻辑)

# ======== 配置区 ========
PROJECT_PREFIX="vertex-api"
DEFAULT_REGION="us-central1"
SERVICE_ACCOUNT_NAME="vertex-automation"
CONFIG_FILE_NAME="vertex-config.json"
KEY_FILE_NAME="vertex-key.json"
MAX_PROJECTS=10

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ======== 全局变量 ========
SELECTED_PROJECT_ID=""

# ==============================================================================
#
#  核心函数库 (Core Functions)
#
# ==============================================================================

generate_random_id() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6; }
get_billing_account() {
  echo -e "${YELLOW}正在获取可用的结算账号...${RESET}"
  BILLING_ACCOUNTS=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" 2>/dev/null)
  if [ -z "$BILLING_ACCOUNTS" ]; then echo -e "${RED}错误：未找到任何有效的结算账号！${RESET}"; return 1; fi
  BILLING_ACCOUNT=$(echo "$BILLING_ACCOUNTS" | awk '{print $1}')
  echo -e "${GREEN}✓ 将使用结算账号: ${BLUE}${BILLING_ACCOUNT}${RESET}"; return 0
}
link_and_verify_billing() {
  local project_id=$1; local billing_account=$2; local max_retries=8; local wait_seconds=15
  echo -e "${YELLOW}步骤A: 检查并关联项目结算...${RESET}"
  billing_status=$(gcloud beta billing projects describe "$project_id" --format="value(billingEnabled)" 2>/dev/null)
  if [ "$billing_status" = "True" ]; then echo -e "${GREEN}✓ 项目 '${project_id}' 的结算已启用。${RESET}"; return 0; fi
  echo -e "${YELLOW}项目结算未启用，正在尝试关联结算账号: ${BLUE}${billing_account}${RESET}"
  gcloud beta billing projects link "$project_id" --billing-account="$billing_account"
  if [ $? -ne 0 ]; then echo -e "${RED}错误：关联结算账号失败！请检查权限或配额。${RESET}"; return 1; fi
  echo -e "${YELLOW}等待结算状态生效...${RESET}"
  for ((i=1; i<=max_retries; i++)); do
    billing_status=$(gcloud beta billing projects describe "$project_id" --format="value(billingEnabled)" 2>/dev/null)
    if [ "$billing_status" = "True" ]; then echo -e "${GREEN}✓ 结算已成功启用！${RESET}"; sleep 10; return 0; fi
    echo -e "${YELLOW}等待中 ($i/$max_retries)...${RESET}"; sleep $wait_seconds
  done
  echo -e "${RED}错误：在超时后结算仍未启用。${RESET}"; return 1
}
ensure_apis_enabled() {
  local project_id=$1
  echo -e "${YELLOW}步骤B: 检查并启用必需的API服务...${RESET}"
  APIS=("aiplatform.googleapis.com" "generativelanguage.googleapis.com" "cloudresourcemanager.googleapis.com" "serviceusage.googleapis.com" "iam.googleapis.com" "apikeys.googleapis.com")
  for api in "${APIS[@]}"; do
    if gcloud services enable "${api}" --project="$project_id" --quiet; then echo -e " - ${GREEN}✓ ${api}${RESET}"; else
      echo -e " - ${RED}✗ 启用 ${api} 失败！正在重试...${RESET}"; sleep 10
      if ! gcloud services enable "${api}" --project="$project_id" --quiet; then echo -e "${RED}错误：重试启用 ${api} 仍然失败。${RESET}"; return 1; fi
      echo -e " - ${GREEN}✓ ${api} (重试成功)${RESET}"
    fi
  done
  echo -e "${GREEN}✓ 所有API均已启用。${RESET}"; echo -e "${YELLOW}等待API服务完全生效（30秒）...${RESET}"; sleep 30; return 0
}
ensure_service_account_and_roles() {
  local project_id=$1; local sa_name=$2; local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"
  echo -e "${YELLOW}步骤C: 检查并配置服务账号及权限...${RESET}"
  if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" --quiet &>/dev/null; then
    echo " - 服务账号不存在，正在创建: ${BLUE}${sa_email}${RESET}"
    gcloud iam service-accounts create "$sa_name" --display-name="Vertex AI Automation" --project="$project_id"
  else echo -e " - ${GREEN}✓ 服务账号已存在: ${BLUE}${sa_email}${RESET}"; fi
  echo " - 分配 'Vertex AI User' 角色..."; gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="roles/aiplatform.user" --quiet
  echo " - 分配 'Service Account User' 角色..."; gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="roles/iam.serviceAccountUser" --quiet
  echo -e "${GREEN}✓ 服务账号和权限配置完成。${RESET}"; return 0
}

# ===== 函数：生成API密钥和配置文件 (已彻底修复捕获逻辑) =====
generate_and_output_config() {
  local project_id=$1; local sa_name=$2; local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"
  echo -e "${YELLOW}步骤D: 生成API密钥、服务账号密钥和配置文件...${RESET}"
  
  # 步骤1: 创建API密钥并捕获其唯一的资源名称
  echo " - 步骤D.1: 创建API密钥资源..." >&2
  local key_name
  key_name=$(gcloud services api-keys create --display-name="Vertex_Auto_Key" --project="$project_id" --format="value(name)" 2>/dev/null)
  
  if [ -z "$key_name" ]; then
    echo -e "${RED}错误：创建API密钥资源失败。请检查权限。${RESET}" >&2
    return 1
  fi
  echo -e "   ${GREEN}✓ API密钥资源创建成功: ${key_name}${RESET}" >&2

  # 步骤2: 使用密钥的资源名称来获取其加密的密钥字符串
  echo " - 步骤D.2: 获取加密的密钥字符串..." >&2
  local api_key
  api_key=$(gcloud services api-keys get-key-string "$key_name" --format="value(keyString)" 2>/dev/null)

  if [ -z "$api_key" ]; then
    echo -e "${RED}错误：获取密钥字符串失败。${RESET}" >&2
    return 1
  fi
  echo -e "   ${GREEN}✓ 成功获取API密钥字符串。${RESET}" >&2

  # 后续流程...
  echo " - 正在生成服务账号密钥文件: ${BLUE}${KEY_FILE_NAME}${RESET}"; rm -f "$KEY_FILE_NAME" 2>/dev/null
  gcloud iam service-accounts keys create "$KEY_FILE_NAME" --iam-account="$sa_email" --project="$project_id"
  echo " - 正在创建配置文件: ${BLUE}${CONFIG_FILE_NAME}${RESET}"; rm -f "$CONFIG_FILE_NAME" 2>/dev/null
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
  echo -e "\n${GREEN}✅ 所有配置已完成！${RESET}"; echo "========================================"
  echo -e "${BLUE}项目ID:${RESET} ${project_id}"; echo -e "${BLUE}API密钥:${RESET} ${api_key}"
  echo -e "${BLUE}配置文件:${RESET} ${CONFIG_FILE_NAME}"; echo -e "${BLUE}密钥文件:${RESET} ${KEY_FILE_NAME}"
  echo "========================================"; echo -e "\n${YELLOW}配置文件内容：${RESET}"; cat "$CONFIG_FILE_NAME" | jq .
  echo -e "\n${YELLOW}正在尝试自动下载配置文件...${RESET}"
  if cloudshell download "$CONFIG_FILE_NAME" && cloudshell download "$KEY_FILE_NAME"; then echo -e "${GREEN}✓ 配置文件和密钥文件下载已启动！${RESET}"; else
    echo -e "${YELLOW}自动下载失败，请在左侧文件浏览器中手动下载 '${CONFIG_FILE_NAME}' 和 '${KEY_FILE_NAME}'。${RESET}"; fi
}

select_project_from_list() {
  SELECTED_PROJECT_ID=""
  echo -e "${YELLOW}正在获取您的项目列表...${RESET}"
  local projects_array=(); while IFS= read -r line; do projects_array+=("$line"); done < <(gcloud projects list --format="value(projectId)")
  if [ ${#projects_array[@]} -eq 0 ]; then echo -e "${RED}错误：未找到任何项目。${RESET}"; return 1; fi
  echo -e "\n请从以下列表中选择一个项目进行操作：\n"; local i=1
  for proj_id in "${projects_array[@]}"; do
    local proj_name=$(gcloud projects describe "$proj_id" --format="value(name)" 2>/dev/null)
    echo -e "  ${YELLOW}${i})${RESET} ${proj_id} (${BLUE}${proj_name:-无名称}${RESET})"; ((i++))
  done
  echo -e "  ${YELLOW}0)${RESET} 取消并返回主菜单"
  local choice
  while true; do
    read -p $'\n请输入选项编号 [0-'$((${#projects_array[@]}))']: ' choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -le ${#projects_array[@]} ]; then break; else
      echo -e "${RED}无效的输入，请输入一个列表中的数字。${RESET}"; fi
  done
  if [ "$choice" -eq 0 ]; then return 0; fi
  SELECTED_PROJECT_ID="${projects_array[$((choice-1))]}"; return 0
}

create_new_project() {
  echo -e "\n${BLUE}--- 开始执行：创建新Vertex AI项目 ---${RESET}"
  local current_projects=$(gcloud projects list --format="value(projectId)" | wc -l)
  if [ "$current_projects" -ge "$MAX_PROJECTS" ]; then echo -e "${RED}错误：已达到项目配额上限 ($MAX_PROJECTS个项目)。${RESET}"; return; fi
  echo -e "${GREEN}✓ 项目配额检查通过 ($current_projects/$MAX_PROJECTS)。${RESET}"
  if ! get_billing_account; then return; fi; local billing_account=$BILLING_ACCOUNT
  local random_suffix=$(generate_random_id); local project_id="${PROJECT_PREFIX}-${random_suffix}"
  echo -e "${YELLOW}正在创建新项目 [${BLUE}${project_id}${YELLOW}]...${RESET}"
  if ! gcloud projects create "$project_id" --name="Vertex-AI-API"; then echo -e "${RED}错误：项目创建失败！${RESET}"; return; fi
  gcloud config set project "$project_id"
  if ! link_and_verify_billing "$project_id" "$billing_account"; then return; fi
  if ! ensure_apis_enabled "$project_id"; then return; fi
  if ! ensure_service_account_and_roles "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  if ! generate_and_output_config "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  echo -e "\n${GREEN}--- 新项目创建流程全部完成 ---${RESET}"
}

check_existing_project() {
  echo -e "\n${BLUE}--- 开始执行：检查现有Vertex AI项目 ---${RESET}"
  select_project_from_list
  if [ $? -ne 0 ]; then return; fi
  local project_id="$SELECTED_PROJECT_ID"
  if [ -z "$project_id" ]; then echo -e "\n${YELLOW}操作已取消，返回主菜单。${RESET}"; return; fi
  echo -e "\n${GREEN}✓ 您已选择项目: ${BLUE}${project_id}${RESET}"; echo -e "${YELLOW}现在将开始检查并配置此项目...${RESET}"
  gcloud config set project "$project_id"
  if ! get_billing_account; then return; fi; local billing_account=$BILLING_ACCOUNT
  if ! link_and_verify_billing "$project_id" "$billing_account"; then return; fi
  if ! ensure_apis_enabled "$project_id"; then return; fi
  if ! ensure_service_account_and_roles "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  if ! generate_and_output_config "$project_id" "$SERVICE_ACCOUNT_NAME"; then return; fi
  echo -e "\n${GREEN}--- 现有项目检查和配置流程全部完成 ---${RESET}"
}

main() {
  if [ -z "$CLOUD_SHELL" ]; then echo -e "${RED}错误：请在Google Cloud Shell中运行此脚本。${RESET}"; exit 1; fi
  if ! command -v jq &> /dev/null; then echo -e "${YELLOW}正在安装jq...${RESET}"; sudo apt-get update -qq > /dev/null && sudo apt-get install -y jq > /dev/null; fi
  while true; do
    clear
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${GREEN}  Vertex AI 项目自动化配置工具 v3.7${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "\n请选择您要执行的操作：\n"
    echo -e "  ${YELLOW}1)${RESET} 创建一个全新的Vertex AI项目并生成配置"
    echo -e "  ${YELLOW}2)${RESET} 检查/修复一个现有项目 (从列表中选择)"
    echo -e "  ${YELLOW}3)${RESET} 清理本项目中所有自动生成的API密钥"
    echo -e "  ${YELLOW}4)${RESET} 退出脚本\n"
    read -p "请输入选项 [1, 2, 3, 4]: " choice
    case $choice in
      1) create_new_project ;;
      2) check_existing_project ;;
      3) cleanup_keys ;;
      4) echo -e "\n${BLUE}再见！${RESET}"; exit 0 ;;
      *) echo -e "\n${RED}无效的选项，请输入 1, 2, 3, 或 4。${RESET}" ;;
    esac
    echo -e "\n"; read -p "按 Enter 键返回主菜单..."
  done
}

# ===== 新增：清理旧密钥的功能 =====
cleanup_keys() {
    echo -e "\n${BLUE}--- 开始清理自动生成的API密钥 ---${RESET}"
    select_project_from_list
    if [ $? -ne 0 ]; then return; fi
    local project_id="$SELECTED_PROJECT_ID"
    if [ -z "$project_id" ]; then echo -e "\n${YELLOW}操作已取消，返回主菜单。${RESET}"; return; fi
    
    echo -e "${YELLOW}正在查找项目 '${project_id}' 中所有名为 'Vertex_Auto_Key' 的密钥...${RESET}"
    local keys_to_delete=()
    while IFS= read -r line; do
        keys_to_delete+=("$line")
    done < <(gcloud services api-keys list --project="$project_id" --filter="displayName=Vertex_Auto_Key" --format="value(name)")

    if [ ${#keys_to_delete[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ 未找到需要清理的密钥。${RESET}"
        return
    fi

    echo -e "${RED}警告：将要删除以下 ${#keys_to_delete[@]} 个API密钥：${RESET}"
    for key_name in "${keys_to_delete[@]}"; do
        echo " - $key_name"
    done

    read -p $'\n您确定要继续吗？(y/N): ' confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}操作已取消。${RESET}"
        return
    fi

    echo -e "${YELLOW}正在删除密钥...${RESET}"
    for key_name in "${keys_to_delete[@]}"; do
        echo " - 删除 $key_name"
        gcloud services api-keys delete "$key_name" --project="$project_id" --quiet
    done
    echo -e "${GREEN}✓ 清理完成！${RESET}"
}

main
