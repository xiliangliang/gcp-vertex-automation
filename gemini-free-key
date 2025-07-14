#!/bin/bash
# 生成谷歌免费key脚本

# ===== 配置 =====
# 自动生成随机用户名
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=75      # 固定创建50个项目
MAX_PARALLEL_JOBS=40   # 默认设置为40 (可根据机器性能和网络调整)
GLOBAL_WAIT_SECONDS=75 # 创建项目和启用API之间的全局等待时间 (秒)
MAX_RETRY_ATTEMPTS=3   # 重试次数
# 只保留纯密钥和逗号分隔密钥文件
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
SECONDS=0
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"
# ===== 配置结束 =====

# ===== 初始化 =====
mkdir -p "$TEMP_DIR"
_log_internal() {
  local level=$1; local msg=$2; local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $msg"
}
_log_internal "INFO" "JSON 解析将仅使用备用方法 (sed/grep)。"
# ===== 初始化结束 =====

# ===== 工具函数 =====
log() { _log_internal "$1" "$2"; }

parse_json() {
  local json="$1"; local field="$2"; local value=""
  if [ -z "$json" ]; then return 1; fi
  case "$field" in
    ".keyString") value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p');;
    *) local field_name=$(echo "$field" | tr -d '.["]'); value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*\")[^\"]*");;
  esac
  if [ -n "$value" ]; then echo "$value"; return 0; else return 1; fi
}

write_keys_to_files() {
    local api_key="$1"
    if [ -z "$api_key" ]; then return; fi
    (
        flock 200
        echo "$api_key" >> "$PURE_KEY_FILE"
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"; fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
    ) 200>"${TEMP_DIR}/key_files.lock"
}

retry_with_backoff() {
  local max_attempts=$1; local cmd=$2; local attempt=1; local timeout=5; local error_log="${TEMP_DIR}/error_$RANDOM.log"
  while [ $attempt -le $max_attempts ]; do
    if bash -c "$cmd" 2>"$error_log"; then rm -f "$error_log"; return 0; fi
    local error_msg=$(cat "$error_log")
    if [[ "$error_msg" == *"Permission denied"* || "$error_msg" == *"Authentication failed"* ]]; then
        log "ERROR" "权限或认证错误，停止重试。"; rm -f "$error_log"; return 1;
    fi
    if [ $attempt -lt $max_attempts ]; then sleep $timeout; timeout=$((timeout * 2)); fi
    attempt=$((attempt + 1))
  done
  log "ERROR" "命令在 $max_attempts 次尝试后最终失败。最后错误: $(cat "$error_log")"; rm -f "$error_log"; return 1
}

show_progress() {
    local completed=$1; local total=$2; if [ $total -le 0 ]; then return; fi
    if [ $completed -gt $total ]; then completed=$total; fi
    local percent=$((completed * 100 / total))
    local completed_chars=$((percent * 50 / 100))
    local remaining_chars=$((50 - completed_chars))
    local progress_bar=$(printf "%${completed_chars}s" "" | tr ' ' '#')
    local remaining_bar=$(printf "%${remaining_chars}s" "")
    printf "\r[%s%s] %d%% (%d/%d)" "$progress_bar" "$remaining_bar" "$percent" "$completed" "$total"
}

generate_report() {
  local success=$1; local attempted=$2; local success_rate=0
  if [ "$attempted" -gt 0 ]; then success_rate=$(echo "scale=2; $success * 100 / $attempted" | bc); fi
  local failed=$((attempted - success)); local duration=$SECONDS; local minutes=$((duration / 60)); local seconds_rem=$((duration % 60))
  echo ""; echo "========== 执行报告 =========="
  echo "计划目标: $attempted 个项目"
  echo "成功获取密钥: $success 个"
  echo "失败: $failed 个"
  echo "成功率: $success_rate%"
  if [ $success -gt 0 ]; then local avg_time=$((duration / success)); echo "平均处理时间 (成功项目): $avg_time 秒/项目"; fi
  echo "总执行时间: $minutes 分 $seconds_rem 秒"
  echo "API密钥已保存至:"
  echo "- 纯API密钥 (每行一个): $PURE_KEY_FILE"
  echo "- 逗号分隔密钥 (单行): $COMMA_SEPARATED_KEY_FILE"
  echo "=========================="
}

task_create_project() {
    local project_id="$1"; local success_file="$2"; local error_log="${TEMP_DIR}/create_${project_id}_error.log"
    if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet >/dev/null 2>"$error_log"; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"
        rm -f "$error_log"; return 0
    else
        log "ERROR" "创建项目失败: $project_id: $(cat "$error_log")"
        rm -f "$error_log"; return 1
    fi
}

task_enable_api() {
    local project_id="$1"; local success_file="$2"; local error_log="${TEMP_DIR}/enable_${project_id}_error.log"
    if retry_with_backoff $MAX_RETRY_ATTEMPTS "gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet 2>\"$error_log\""; then
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"
        rm -f "$error_log"; return 0
    else
        log "ERROR" "启用API失败: $project_id: $(cat "$error_log")"
        rm -f "$error_log"; return 1
    fi
}

task_create_key() {
    local project_id="$1"; local error_log="${TEMP_DIR}/key_${project_id}_error.log"; local create_output
    if ! create_output=$(retry_with_backoff $MAX_RETRY_ATTEMPTS "gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini API Key for $project_id\" --format=\"json\" --quiet 2>\"$error_log\""); then
        log "ERROR" "创建密钥失败: $project_id: $(cat "$error_log")"
        rm -f "$error_log"; return 1
    fi
    local api_key; api_key=$(parse_json "$create_output" ".keyString")
    if [ -n "$api_key" ]; then
        log "SUCCESS" "成功提取密钥: $project_id"
        write_keys_to_files "$api_key"; rm -f "$error_log"; return 0
    else
        log "ERROR" "提取密钥失败: $project_id (无法从gcloud输出解析keyString)"
        rm -f "$error_log"; return 1
    fi
}

# --- 新增任务函数 ---
task_list_keys_for_project() {
    local project_id="$1"
    # run_parallel的第二个参数是success_file，这里我们忽略它
    local error_log="${TEMP_DIR}/list_keys_${project_id}_error.log"
    local keys_json
    # 对于未启用API的项目，此命令会失败，这是正常现象，所以我们不记录为严重错误
    if ! keys_json=$(gcloud services api-keys list --project="$project_id" --format="json" --quiet 2>"$error_log"); then
        rm -f "$error_log"; return 0
    fi
    rm -f "$error_log"

    if [ -z "$keys_json" ] || [ "$keys_json" == "[]" ]; then
        return 0 # 未找到密钥，不是错误
    fi

    # 提取所有keyString的值
    local keys=$(echo "$keys_json" | grep -oP '(?<="keyString": ")[^"]*')
    if [ -n "$keys" ]; then
        (
            flock 200
            echo "项目: $project_id" >> "$DETAILED_OUTPUT_FILE"
            echo "$keys" | while IFS= read -r key; do
                echo "  - 密钥: $key" >> "$DETAILED_OUTPUT_FILE"
                echo "$key" >> "$ALL_KEYS_FILE" # 将每个key单独存入一个文件，便于后续处理
            done
        ) 200>"${TEMP_DIR}/list_keys.lock"
    fi
    return 0
}


delete_project() {
  local project_id="$1"; local error_log="${TEMP_DIR}/delete_${project_id}_error.log"
  if gcloud projects delete "$project_id" --quiet 2>"$error_log"; then
    log "SUCCESS" "成功删除项目: $project_id"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已删除: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    rm -f "$error_log"; return 0
  else
    log "ERROR" "删除项目失败: $project_id: $(cat "$error_log")"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除失败: $project_id - $(cat "$error_log")" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    rm -f "$error_log"; return 1
  fi
}

cleanup_resources() {
  log "INFO" "执行退出清理..."; if [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
}
# ===== 工具函数结束 =====

# ===== 功能模块 =====
run_parallel() {
    local task_func="$1"; local description="$2"; local success_file="$3"; shift 3; local items=("$@")
    local total_items=${#items[@]}; if [ $total_items -eq 0 ]; then log "INFO" "在 '$description' 阶段没有项目需要处理。"; return 0; fi
    local active_jobs=0; local completed_count=0; local success_count=0; local fail_count=0; local pids=()
    log "INFO" "开始并行执行 '$description' (最多 $MAX_PARALLEL_JOBS 个并行)..."
    for item in "${items[@]}"; do
        "$task_func" "$item" "$success_file" &
        pids+=($!); ((active_jobs++))
        if [[ "$active_jobs" -ge "$MAX_PARALLEL_JOBS" ]]; then wait -n; ((active_jobs--)); fi
    done
    for pid in "${pids[@]}"; do
        wait "$pid"; local exit_status=$?; ((completed_count++))
        if [ $exit_status -eq 0 ]; then ((success_count++)); else ((fail_count++)); fi
        show_progress $completed_count $total_items; echo -n " $description 中 (S:$success_count F:$fail_count)..."
    done
    echo; log "INFO" "阶段 '$description' 完成。成功: $success_count, 失败: $fail_count"
    log "INFO" "======================================================"
    if [ $fail_count -gt 0 ]; then return 1; else return 0; fi
}

create_projects_and_get_keys_fast() {
    SECONDS=0
    log "INFO" "======================================================"
    log "INFO" "高速模式: 创建固定的 $TOTAL_PROJECTS 个项目并获取API密钥"
    log "INFO" "======================================================"
    log "INFO" "将使用随机生成的用户名: ${EMAIL_USERNAME}"
    log "INFO" "脚本将在 3 秒后开始执行..."; sleep 3

    > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num=$(printf "%03d" $i)
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        local project_id=$(echo "$base_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        if ! [[ "$project_id" =~ ^[a-z] ]]; then project_id="g${project_id:1}"; project_id=$(echo "$project_id" | cut -c 1-30 | sed 's/-$//'); fi
        projects_to_create+=("$project_id")
    done

    # --- PHASE 1: Create Projects ---
    local CREATED_PROJECTS_FILE="${TEMP_DIR}/created_projects.txt"; > "$CREATED_PROJECTS_FILE"
    export -f task_create_project log retry_with_backoff; export TEMP_DIR MAX_RETRY_ATTEMPTS
    run_parallel task_create_project "阶段1: 创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"
    local created_project_ids=(); if [ -f "$CREATED_PROJECTS_FILE" ]; then mapfile -t created_project_ids < "$CREATED_PROJECTS_FILE"; fi
    if [ ${#created_project_ids[@]} -eq 0 ]; then log "ERROR" "项目创建阶段失败，没有任何项目成功创建。中止操作。"; return 1; fi

    # --- PHASE 2: Global Wait ---
    log "INFO" "阶段2: 全局等待 ${GLOBAL_WAIT_SECONDS} 秒，以便GCP后端同步项目状态..."
    for ((i=1; i<=${GLOBAL_WAIT_SECONDS}; i++)); do sleep 1; show_progress $i ${GLOBAL_WAIT_SECONDS}; echo -n " 等待中..."; done
    echo; log "INFO" "等待完成。"; log "INFO" "======================================================"

    # --- PHASE 3: Enable APIs ---
    local ENABLED_PROJECTS_FILE="${TEMP_DIR}/enabled_projects.txt"; > "$ENABLED_PROJECTS_FILE"
    export -f task_enable_api log retry_with_backoff; export TEMP_DIR MAX_RETRY_ATTEMPTS
    run_parallel task_enable_api "阶段3: 启用API" "$ENABLED_PROJECTS_FILE" "${created_project_ids[@]}"
    local enabled_project_ids=(); if [ -f "$ENABLED_PROJECTS_FILE" ]; then mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"; fi
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then log "ERROR" "API启用阶段失败，没有任何项目成功启用API。中止操作。"; generate_report 0 $TOTAL_PROJECTS; return 1; fi

    # --- PHASE 4: Create Keys ---
    export -f task_create_key log retry_with_backoff parse_json write_keys_to_files; export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE
    run_parallel task_create_key "阶段4: 创建密钥" "/dev/null" "${enabled_project_ids[@]}"

    # --- FINAL REPORT ---
    local successful_keys=$(wc -l < "$PURE_KEY_FILE" | xargs)
    generate_report "$successful_keys" "$TOTAL_PROJECTS"
    log "INFO" "======================================================"
    log "INFO" "请检查文件 '$PURE_KEY_FILE' 和 '$COMMA_SEPARATED_KEY_FILE' 中的内容"
    
    # --- 新增: 在控制台打印逗号分隔的密钥 ---
    if [ -s "$COMMA_SEPARATED_KEY_FILE" ]; then
        log "INFO" "===== 生成的API密钥 (逗号分隔) ====="
        cat "$COMMA_SEPARATED_KEY_FILE"
        echo # for a newline
        log "INFO" "======================================="
    fi

    if [ "$successful_keys" -lt "$TOTAL_PROJECTS" ]; then log "WARN" "有 $((TOTAL_PROJECTS - successful_keys)) 个项目未能成功获取密钥，请检查上方日志了解详情。"; fi
    log "INFO" "提醒：项目需要关联有效的结算账号才能实际使用 API 密钥"
    log "INFO" "======================================================"
}

# --- 新增功能模块 ---
list_all_existing_keys() {
    SECONDS=0
    log "INFO" "======================================================"
    log "INFO" "功能: 查询所有现有项目的API密钥"
    log "INFO" "======================================================"
    log "INFO" "正在获取项目列表..."
    local list_error="${TEMP_DIR}/list_projects_error.log"
    local ALL_PROJECTS=($(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet 2>"$list_error"))
    if [ $? -ne 0 ]; then log "ERROR" "无法获取项目列表: $(cat "$list_error")"; rm -f "$list_error"; return 1; fi
    rm -f "$list_error"

    if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then
        log "INFO" "未找到任何用户项目。"
        return 0
    fi
    log "INFO" "找到 ${#ALL_PROJECTS[@]} 个项目，将开始并行查询密钥..."

    # 准备临时文件
    export DETAILED_OUTPUT_FILE="${TEMP_DIR}/detailed_keys.txt"
    export ALL_KEYS_FILE="${TEMP_DIR}/all_keys_flat.txt"
    > "$DETAILED_OUTPUT_FILE"; > "$ALL_KEYS_FILE"

    # 导出函数和变量以供并行任务使用
    export -f task_list_keys_for_project log show_progress
    export TEMP_DIR MAX_PARALLEL_JOBS

    # 并行执行密钥查询
    run_parallel task_list_keys_for_project "查询密钥" "/dev/null" "${ALL_PROJECTS[@]}"

    # 显示结果
    echo
    log "INFO" "==================== 查询结果 ===================="
    if [ -s "$DETAILED_OUTPUT_FILE" ]; then
        cat "$DETAILED_OUTPUT_FILE"
    else
        log "INFO" "在所有项目中均未找到任何API密钥。"
    fi

    if [ -s "$ALL_KEYS_FILE" ]; then
        log "INFO" "---------- 所有密钥 (逗号分隔) ----------"
        local comma_separated_keys=$(paste -sd, "$ALL_KEYS_FILE")
        echo "$comma_separated_keys"
        log "INFO" "-------------------------------------------"
    fi
    local duration=$SECONDS
    log "INFO" "查询完成，总耗时: ${duration} 秒。"
    log "INFO" "======================================================"
}


delete_all_existing_projects() {
  SECONDS=0
  log "INFO" "======================================================"; log "INFO" "功能: 删除所有现有项目"; log "INFO" "======================================================"
  log "INFO" "正在获取项目列表..."; local list_error="${TEMP_DIR}/list_projects_error.log"; local ALL_PROJECTS=($(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet 2>"$list_error")); local list_ec=$?; rm -f "$list_error"
  if [ $list_ec -ne 0 ]; then log "ERROR" "无法获取项目列表: $(cat "$list_error")"; return 1; fi
  if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then log "INFO" "未找到任何用户项目，无需删除"; return 0; fi
  local total_to_delete=${#ALL_PROJECTS[@]}
  log "INFO" "找到 $total_to_delete 个用户项目需要删除";
  read -p "!!! 危险操作 !!! 确认要删除所有 $total_to_delete 个项目吗？(输入 'DELETE-ALL' 确认): " confirm; if [ "$confirm" != "DELETE-ALL" ]; then log "INFO" "删除操作已取消"; return 1; fi
  echo "项目删除日志 ($(date +%Y-%m-%d_%H:%M:%S))" > "$DELETION_LOG"; echo "------------------------------------" >> "$DELETION_LOG"
  export -f delete_project log retry_with_backoff show_progress; export DELETION_LOG TEMP_DIR MAX_PARALLEL_JOBS MAX_RETRY_ATTEMPTS
  run_parallel delete_project "删除项目" "/dev/null" "${ALL_PROJECTS[@]}"
  local successful_deletions=$(grep -c "已删除:" "$DELETION_LOG")
  local failed_deletions=$(grep -c "删除失败:" "$DELETION_LOG")
  local duration=$SECONDS; local minutes=$((duration / 60)); local seconds_rem=$((duration % 60))
  echo ""; echo "========== 删除报告 =========="; echo "总计尝试删除: $total_to_delete 个项目"; echo "成功删除: $successful_deletions 个项目"; echo "删除失败: $failed_deletions 个项目"; echo "总执行时间: $minutes 分 $seconds_rem 秒"; echo "详细日志已保存至: $DELETION_LOG"; echo "=========================="
}

show_menu() {
  clear
  echo "======================================================"
  echo "     GCP Gemini API 密钥懒人管理工具 v3.2 (增强版)"
  echo "======================================================"
  local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1); if [ -z "$current_account" ]; then current_account="无法获取"; fi
  local current_project; current_project=$(gcloud config get-value project 2>/dev/null); if [ -z "$current_project" ]; then current_project="未设置"; fi
  echo "当前账号: $current_account"; echo "当前项目: $current_project"
  echo "固定创建数量: $TOTAL_PROJECTS"; echo "并行任务数: $MAX_PARALLEL_JOBS"; echo "全局等待: ${GLOBAL_WAIT_SECONDS}s"
  echo ""; echo "请选择功能:";
  echo "1. [极限速度] 一键创建${TOTAL_PROJECTS}个项目并获取API密钥"
  echo "2. 查询并打印所有现有项目的API密钥"
  echo "3. 一键删除所有现有项目"
  echo "4. 修改配置参数"
  echo "0. 退出"
  echo "======================================================"
  read -p "请输入选项 [0-4]: " choice

  case $choice in
    1) create_projects_and_get_keys_fast ;;
    2) list_all_existing_keys ;;
    3) delete_all_existing_projects ;;
    4) configure_settings ;;
    0) log "INFO" "正在退出..."; exit 0 ;;
    *) echo "无效选项 '$choice'，请重新选择。"; sleep 2 ;;
  esac
  if [[ "$
