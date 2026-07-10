#!/bin/bash
# linyaps binary 項目前置檢測腳本 — 檢查 pak_linyaps.sh 完整度
# 用法: ./validate_projects.sh --task-file=<task.json> [options]
# 依賴: scripts/common.sh（共享庫）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/common.sh"

TASK_FILE=""
PKG_NAME=""
PROJECTS_ROOT=""
OUTPUT_FILE=""

show_help() {
    cat <<'HELP'
linyaps binary 項目前置檢測腳本

用法:
  ./validate_projects.sh --task-file=<task.json> [options]
  ./validate_projects.sh --pkg-name=<names> --projects-root=<path> [options]

必要參數（至少指定一個）:
  --task-file=<file>    任務 JSON 文件路徑
  --pkg-name=<names>    逗號分隔的包名列表

選項:
  --projects-root=<path>  項目根目錄
  --output=<file.json>    結果輸出文件路徑（JSON 格式）
  --help                  顯示此說明

退出碼:
  0  — 全部通過
  1  — 存在失敗
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-file=*)    TASK_FILE="${1#*=}"; shift ;;
        --pkg-name=*)     PKG_NAME="${1#*=}"; shift ;;
        --projects-root=*) PROJECTS_ROOT="${1#*=}"; shift ;;
        --output=*)       OUTPUT_FILE="${1#*=}"; shift ;;
        --help)           show_help ;;
        *)                log_err "未知參數: $1"; show_help ;;
    esac
done

if [[ -z "$TASK_FILE" && -z "$PKG_NAME" ]]; then
    log_err "至少需要指定一個參數: --task-file 或 --pkg-name"
    show_help
fi

if [[ -n "$TASK_FILE" && ! -f "$TASK_FILE" ]]; then
    log_err "任務文件不存在: $TASK_FILE"
    exit 1
fi

check_python3

declare -a ALL_PKG_NAMES=()
CLI_PROJECTS_ROOT=""
JSON_PROJECTS_ROOT=""

if [[ -n "$TASK_FILE" ]]; then
    PARSE_RESULT=$(python3 -c "
import json, sys
with open('${TASK_FILE}') as f:
    data = json.load(f)
g = data.get('global', {})
projects_root = g.get('projects_root', '') or ''
tasks = data.get('tasks', [])
print('JSON_PROJECTS_ROOT=' + json.dumps(projects_root))
print('JSON_TASK_COUNT=' + str(len(tasks)))
for i, t in enumerate(tasks):
    print(f'TASK_{i}_PKGNAME=' + json.dumps(t.get('pkgName', '')))
" 2>/dev/null) || { log_err "JSON 解析失敗"; exit 1; }

    eval "$PARSE_RESULT"
    JSON_PROJECTS_ROOT=$(json_strip "$JSON_PROJECTS_ROOT")

    for ((i = 0; i < JSON_TASK_COUNT; i++)); do
        pkg_var="TASK_${i}_PKGNAME"
        pkg_name="${!pkg_var}"
        pkg_name=$(json_strip "$pkg_name")
        [[ -n "$pkg_name" ]] && ALL_PKG_NAMES+=("$pkg_name")
    done
    log_info "從 JSON 讀取到 $JSON_TASK_COUNT 個包名"
fi

if [[ -n "$PKG_NAME" ]]; then
    IFS=',' read -ra CLI_PKGS <<< "$PKG_NAME"
    for pkg in "${CLI_PKGS[@]}"; do
        pkg="$(echo "$pkg" | xargs)"
        [[ -n "$pkg" ]] && ALL_PKG_NAMES+=("$pkg")
    done
    log_info "從 --pkg-name 讀取到 ${#CLI_PKGS[@]} 個包名"
fi

TASK_COUNT="${#ALL_PKG_NAMES[@]}"
if [[ $TASK_COUNT -eq 0 ]]; then
    log_err "未讀取到任何有效的包名"
    exit 1
fi

CLI_PROJECTS_ROOT="$PROJECTS_ROOT"
if [[ -n "$CLI_PROJECTS_ROOT" ]]; then
    PROJECTS_ROOT="$CLI_PROJECTS_ROOT"
else
    PROJECTS_ROOT="$JSON_PROJECTS_ROOT"
fi

if [[ -z "$PROJECTS_ROOT" ]]; then
    log_err "未指定 projects-root"
    exit 1
fi

PROJECTS_ROOT="$(cd "$PROJECTS_ROOT" 2>/dev/null && pwd)" || {
    log_err "項目根目錄不存在: $PROJECTS_ROOT"
    exit 1
}

log_info "項目根目錄: $PROJECTS_ROOT"
log_info "任務數量:   $TASK_COUNT"
echo ""

declare -a STATUSES=()
declare -a DIRS=()
declare -a MESSAGES=()
PASS_COUNT=0
FAIL_COUNT=0

for pkg_name in "${ALL_PKG_NAMES[@]}"; do
    project_dir=$(find_project_dir "$pkg_name" "$PROJECTS_ROOT") || true

    if [[ -z "$project_dir" ]]; then
        STATUSES+=("NOT_FOUND")
        DIRS+=("")
        MESSAGES+=("項目目錄不存在")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    entry_file="$project_dir/pak_linyaps.sh"
    if [[ ! -f "$entry_file" ]]; then
        STATUSES+=("FAIL")
        DIRS+=("$project_dir")
        MESSAGES+=("缺少 pak_linyaps.sh")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if [[ ! -x "$entry_file" ]]; then
        chmod +x "$entry_file"
    fi

    STATUSES+=("PASS")
    DIRS+=("$project_dir")
    MESSAGES+=("")
    PASS_COUNT=$((PASS_COUNT + 1))
done

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          linyaps binary 項目前置檢測結果                                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

printf "${BOLD}%-8s | %-30s | %-50s | %s${NC}\n" "狀態" "包名" "項目目錄" "說明"
printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────"

for ((i = 0; i < TASK_COUNT; i++)); do
    pkg="${ALL_PKG_NAMES[$i]}"
    status="${STATUSES[$i]}"
    dir="${DIRS[$i]}"
    msg="${MESSAGES[$i]}"
    case "$status" in
        PASS)      printf "${GREEN}PASS    ${NC}| %-30s | %-50s | %s\n" "$pkg" "$dir" "✓" ;;
        FAIL)      printf "${RED}FAIL    ${NC}| %-30s | %-50s | %s\n" "$pkg" "$dir" "✗ $msg" ;;
        NOT_FOUND) printf "${YELLOW}NOT_FOUND${NC}| %-30s | %-50s | %s\n" "$pkg" "-" "✗ $msg" ;;
    esac
done

echo ""
echo -e "總計: $TASK_COUNT | ${GREEN}通過: $PASS_COUNT${NC} | ${RED}失敗: $FAIL_COUNT${NC}"

if [[ -n "$OUTPUT_FILE" ]]; then
    json_results="["
    for ((i = 0; i < TASK_COUNT; i++)); do
        [[ $i -gt 0 ]] && json_results+=","
        pkg="${ALL_PKG_NAMES[$i]}"
        status="${STATUSES[$i]}"
        dir="${DIRS[$i]}"
        msg="${MESSAGES[$i]}"
        json_results+="{\"pkgName\":\"${pkg}\",\"status\":\"${status}\",\"project_dir\":\"${dir}\",\"message\":\"${msg}\"}"
    done
    json_results+="]"
    timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    python3 -c "
import json
result = {
    \"validated_at\": \"${timestamp}\",
    \"projects_root\": \"${PROJECTS_ROOT}\",
    \"summary\": {\"total\": ${TASK_COUNT}, \"passed\": ${PASS_COUNT}, \"failed\": ${FAIL_COUNT}},
    \"results\": ${json_results}
}
with open('${OUTPUT_FILE}', 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
" 2>/dev/null || log_warn "JSON 結果文件寫入失敗: $OUTPUT_FILE"
    log_info "結果已寫入: $OUTPUT_FILE"
fi

echo ""
if [[ $FAIL_COUNT -eq 0 ]]; then
    log_ok "所有 binary 項目驗證通過！"
    exit 0
else
    log_err "存在 $FAIL_COUNT 個檢測未通過的項目"
    exit 1
fi
