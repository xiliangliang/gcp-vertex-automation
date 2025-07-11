#!/bin/bash
# 文件名：manage_gemini_keys.sh
# 功能：一个多功能的Gemini API密钥管理工具。
#       支持：1. 为单个项目创建密钥
#             2. 批量创建项目并生成密钥
#             3. 查询单个或所有项目的现有密钥

# ======== 颜色定义 ========
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ======== 辅助函数 ========

# 函数：打印错误信息并退出
function error_exit() {
  echo -e "\n${RED}❌ 错误: $1${RESET}\n"
  exit 1
}

# 函数：等待用户按键继续
function press_any_key_to_continue() {
  echo ""
  read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 函数：检查依赖工具和登录状态
function check_dependencies() {
  echo -e "${YELLOW}正在检查依赖工具...${RESET}"
  for tool in gcloud jq column; do
    if ! command -v "$tool" &> /dev/null; then
      error_exit "${tool} CLI 未安装。请先安装它。 (例如: sudo apt-get install ${tool} 或 brew install ${tool})"
    fi
  done
  
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '@'; then
    echo -e "${YELLOW}您尚未登录 gcloud。正在引导您登录...${RESET}"
    gcloud auth login --quiet || error_exit "gcloud 登录失败。"
    gcloud auth application-default login --quiet || error_exit "gcloud 应用默认凭证设置失败。"
  fi
  echo -e "${GREEN}✓ 依赖和登录状态正常。${RESET}"
}

# ======== 查询功能模块 ========

# 函数：选择一个项目 (仅选择，不创建)
function select_project() {
  echo -e "\n${YELLOW}正在获取GCP项目列表...${RESET}"
  PROJECT_LIST=$(gcloud projects list --format="value(projectId,name)" --sort-by=projectId)
  
  if [ -z "$PROJECT_LIST" ]; then
    echo -e "${RED}未找到任何GCP项目。无法继续查询。${RESET}"
    return 1
  fi
  
  echo "发现以下项目:"
  echo -e "${BLUE}"
  awk '{print NR, $1, "(" $2 ")"}' <<< "$PROJECT_LIST"
  echo -e "${RESET}"
  read -p "请选择要查询的项目编号: " CHOICE
  
  PROJECT_ID=$(echo "$PROJECT_LIST" | awk -v choice="$CHOICE" 'NR==choice {print $1}')
  if [ -z "$PROJECT_ID" ]; then
      echo -e "${RED}无效的选择。${RESET}"
      return 1
  fi
  echo -e "${GREEN}✓ 已选择项目: ${BLUE}${PROJECT_ID}${RESET}"
  return 0
}

# 函数：查询单个项目的API密钥
function query_single_project_keys() {
  if ! select_project; then
    return
  fi
  
  echo -e "\n${YELLOW}正在查询项目 ${BLUE}${PROJECT_ID}${RESET} 的API密钥...${RESET}"
  # --format 使用 value() 可以直接获取值，更简洁
  KEYS_INFO=$(gcloud beta services api-keys list --project="$PROJECT_ID" --format="value(displayName,keyString)")
  
  if [ -z "$KEYS_INFO" ]; then
    echo -e "${GREEN}在项目 ${BLUE}${PROJECT_ID}${RESET} 中未找到任何API密钥。${RESET}"
  else
    echo -e "${GREEN}查询结果如下:${RESET}"
    echo "====================================================================================="
    echo -e "${BLUE}显示名称\tAPI密钥${RESET}"
    echo "$KEYS_INFO" | column -t
    echo "====================================================================================="
  fi
}

# 函数：查询所有项目的API密钥
function query_all_projects_keys() {
  echo -e "\n${YELLOW}正在查询您账户下所有项目的API密钥...${RESET}"
  echo -e "${YELLOW}注意：如果项目数量较多，此过程可能需要一些时间。${RESET}"
  
  ALL_PROJECTS=$(gcloud projects list --format="value(projectId)")
  if [ -z "$ALL_PROJECTS" ]; then
    echo -e "${RED}未找到任何GCP项目。${RESET}"
    return
  fi
  
  # 准备最终输出的表头
  FINAL_SUMMARY="项目ID,密钥显示名称,API密钥\n"
  FOUND_ANY_KEY=false
  
  for PROJECT_ID in $ALL_PROJECTS; do
    echo -e "  -> 正在扫描项目: ${BLUE}${PROJECT_ID}${RESET}..."
    # 使用JSON格式，方便jq处理，并抑制错误输出（如API未启用等）
    KEYS_JSON=$(gcloud beta services api-keys list --project="$PROJECT_ID" --format="json" 2>/dev/null)
    
    if [ -n "$KEYS_JSON" ] && [ "$KEYS_JSON" != "[]" ]; then
      FOUND_ANY_KEY=true
      # 使用jq将每个密钥信息格式化为CSV行
      SUMMARY_PART=$(echo "$KEYS_JSON" | jq -r --arg pid "$PROJECT_ID" '.[] | "\($pid),\(.displayName),\(.keyString)"')
      FINAL_SUMMARY+="${SUMMARY_PART}\n"
    fi
  done
  
  if ! $FOUND_ANY_KEY; then
    echo -e "\n${GREEN}在您所有的项目中均未找到任何API密钥。${RESET}"
  else
    echo -e "\n${GREEN}✅ 所有项目扫描完成！汇总结果如下：${RESET}"
    echo "========================================================================================================"
    # 使用 column 工具格式化CSV输出，使其对齐
    echo -e "${FINAL_SUMMARY}" | column -t -s ','
    echo "========================================================================================================"
  fi
}

# ======== 创建功能模块 (从之前的脚本整合而来) ========

# 函数：运行单项目创建流程 (原 enhanced_gemini_key.sh)
function run_single_creation() {
    # 此处粘贴 enhanced_gemini_key.sh 的 main 函数内容，并稍作修改
    # 为避免函数名冲突和重复，直接将逻辑内联或重构
    source <(curl -sL https://raw.githubusercontent.com/woniucloud/gke/main/gemini.sh)
}

# 函数：运行批量创建流程 (原 batch_create_gemini_keys.sh)
function run_batch_creation() {
    # 此处粘贴 batch_create_gemini_keys.sh 的 main 函数内容，并稍作修改
    source <(curl -sL https://raw.githubusercontent.com/woniucloud/gke/main/gemini-batch.sh)
}


# ======== 主菜单和主函数 ========

function main_menu() {
  clear
  echo -e "${YELLOW}========== Gemini API 密钥管理器 ==========${RESET}"
  echo -e "${GREEN}请选择您要执行的操作:${RESET}"
  echo "-------------------------------------------"
  echo -e "  ${BLUE}1.${RESET} 创建新的API密钥 (单个项目)"
  echo -e "  ${BLUE}2.${RESET} 批量创建项目和密钥"
  echo "-------------------------------------------"
  echo -e "  ${BLUE}3.${RESET} 查询单个项目的API密钥"
  echo -e "  ${BLUE}4.${RESET} 查询所有项目的API密钥"
  echo "-------------------------------------------"
  echo -e "  ${RED}5.${RESET} 退出"
  echo "==========================================="
  read -p "请输入选项 [1-5]: " CHOICE
  
  case $CHOICE in
    1)
      run_single_creation
      press_any_key_to_continue
      ;;
    2)
      run_batch_creation
      press_any_key_to_continue
      ;;
    3)
      query_single_project_keys
      press_any_key_to_continue
      ;;
    4)
      query_all_projects_keys
      press_any_key_to_continue
      ;;
    5)
      echo -e "\n${GREEN}感谢使用，再见！${RESET}"
      exit 0
      ;;
    *)
      echo -e "\n${RED}无效的输入，请输入 1 到 5 之间的数字。${RESET}"
      sleep 2
      ;;
  esac
}

# 主执行逻辑
function main() {
  check_dependencies
  while true; do
    main_menu
  done
}

# 运行主函数
main
