#!/bin/bash
# linyaps 項目前置檢測腳本
# 在 run_tasks.sh 之前執行，一次性校驗所有任務的項目目錄及 pak_linyaps.sh 完整度
#
# 用法:
#   ./scripts/validate_projects.sh --task-file=<task.json> [options]
#   ./scripts/validate_projects.sh --pkg-name=<name1,name2> --projects-root=<path> [options]
#
# 必要參數（二選一）:
#   --task-file=<file>    任務 JSON 文件路徑（從 tasks[].pkgName 讀取包名，同時讀取 global.projects_root）
#   --pkg-name=<names>    逗號分隔的包名列表（例如 com.opera.browser,com.visualstudio.code）
#                         適用於非 JSON 場景（如自然語言任務輸入）
#
# 選項:
#   --projects-root=<path>  項目根目錄（覆蓋 JSON 中的 projects_root 設定）
#   --output=<file.json>    結果輸出文件路徑（JSON 格式）
#   --help                  顯示此說明
#
# 退出碼:
#   0 — 全部通過（所有任務的項目目錄完整）
#   1 — 存在失敗（有任務找不到項目目錄或缺少 pak_linyaps.sh）
#
# 輸出:
#   終端 — 格式化對齊表格（顏色標記 PASS / FAIL / NOT_FOUND）
#   JSON — 結果文件（--output 指定路徑）
#
# 檢測邏輯（對每個任務）:
#   1. 在 projects-root 下查找對應項目目錄
#      - 優先 CI_ll_<pkgName> 格式
#      - 其次 <pkgName> 直接匹配
#      - 最後模糊搜索
#   2. 確認目錄下存在 pak_linyaps.sh 且可執行

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 顏色定義
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================
# 默認參數值
# ============================================================
TASK_FILE=""
PKG_NAME=""
PROJECTS_ROOT=""
OUTPUT_FILE=""

# ============================================================
# 使用說明
# ============================================================
show_help() {
    cat <<'HELP'
linyaps 項目前置檢測腳本 — 在打包前校驗所有任務的項目目錄完整度

用法:
  # 從 JSON 任務文件讀取包名
  ./scripts/validate_projects.sh --task-file=<task.json> [options]

  # 直接指定包名（適用於非 JSON 的自然語言場景）
  ./scripts/validate_projects.sh --pkg-name=<names> --projects-root=<path> [options]

必要參數（至少指定一個，可同時使用）:
  --task-file=<file>    任務 JSON 文件路徑（從 tasks[].pkgName 讀取包名）
  --pkg-name=<names>    逗號分隔的包名列表（例如 com.opera.browser,com.visualstudio.code）

選項:
  --projects-root=<path>  項目根目錄（覆蓋 JSON 中的 projects_root 設定）
  --output=<file.json>    結果輸出文件路徑（JSON 格式）
  --help                  顯示此說明

退出碼:
  0  — 全部通過，可繼續打包
  1  — 存在失敗，需先處理不完整的項目

檢測邏輯（對每個任務）:
  1. 在 projects-root 下查找對應項目目錄
     - 優先 CI_ll_<pkgName> 格式
     - 其次 <pkgName> 直接匹配
     - 最後模糊搜索
  2. 確認目錄下存在 pak_linyaps.sh 且可執行
HELP
    exit 0
}

# ============================================================
# 參數解析
# ============================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-file=*)
            TASK_FILE="${1#*=}"
            shift
            ;;
        --pkg-name=*)
            PKG_NAME="${1#*=}"
            shift
            ;;
        --projects-root=*)
            PROJECTS_ROOT="${1#*=}"
            shift
            ;;
        --output=*)
            OUTPUT_FILE="${1#*=}"
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            log_err "未知參數: $1"
            log_info "使用 --help 查看說明"
            exit 1
            ;;
    esac
done

# ============================================================
# 前置檢查
# ============================================================
if [[ -z "$TASK_FILE" && -z "$PKG_NAME" ]]; then
    log_err "至少需要指定一個參數: --task-file 或 --pkg-name"
    log_info "使用 --help 查看說明"
    exit 1
fi

if [[ -n "$TASK_FILE" && ! -f "$TASK_FILE" ]]; then
    log_err "任務文件不存在: $TASK_FILE"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    log_err "需要 python3 來解析 JSON"
    exit 1
fi

# ============================================================
# 步驟 1: 收集包名列表
# ============================================================

declare -a ALL_PKG_NAMES=()
CLI_PROJECTS_ROOT=""
JSON_PROJECTS_ROOT=""

# 1a: 從 JSON 提取（若指定 --task-file）
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
" 2>/dev/null) || {
        log_err "JSON 解析失敗: $TASK_FILE"
        exit 1
    }

    eval "$PARSE_RESULT"
    JSON_PROJECTS_ROOT="${JSON_PROJECTS_ROOT//\"/}"

    for ((i = 0; i < JSON_TASK_COUNT; i++)); do
        pkg_var="TASK_${i}_PKGNAME"
        pkg_name="${!pkg_var}"
        pkg_name="${pkg_name//\"/}"
        [[ -n "$pkg_name" ]] && ALL_PKG_NAMES+=("$pkg_name")
    done

    log_info "從 JSON 讀取到 $JSON_TASK_COUNT 個包名"
fi

# 1b: 從 --pkg-name 提取（若指定）
if [[ -n "$PKG_NAME" ]]; then
    IFS=',' read -ra CLI_PKGS <<< "$PKG_NAME"
    for pkg in "${CLI_PKGS[@]}"; do
        pkg="$(echo "$pkg" | xargs)"  # trim whitespace
        [[ -n "$pkg" ]] && ALL_PKG_NAMES+=("$pkg")
    done
    log_info "從 --pkg-name 讀取到 ${#CLI_PKGS[@]} 個包名"
fi

TASK_COUNT="${#ALL_PKG_NAMES[@]}"

if [[ $TASK_COUNT -eq 0 ]]; then
    log_err "未讀取到任何有效的包名"
    exit 1
fi

# 保存命令列傳入的 PROJECTS_ROOT（優先使用）
CLI_PROJECTS_ROOT="$PROJECTS_ROOT"

# 優先使用命令列傳入的 --projects-root，否則回退到 JSON 中的值
if [[ -n "$CLI_PROJECTS_ROOT" ]]; then
    PROJECTS_ROOT="$CLI_PROJECTS_ROOT"
else
    PROJECTS_ROOT="$JSON_PROJECTS_ROOT"
fi

if [[ -z "$PROJECTS_ROOT" ]]; then
    log_err "未指定 projects-root（命令列未傳入，且 JSON 中 global.projects_root 為空）"
    log_info "請使用 --projects-root=<path> 指定"
    exit 1
fi

# 轉換為絕對路徑
PROJECTS_ROOT="$(cd "$PROJECTS_ROOT" 2>/dev/null && pwd)" || {
    log_err "項目根目錄不存在或無法訪問: $PROJECTS_ROOT"
    exit 1
}

log_info "項目根目錄: $PROJECTS_ROOT"
log_info "任務數量:   $TASK_COUNT"
echo ""

# ============================================================
# 步驟 2: 逐任務檢測
# ============================================================

# 初始化結果數組
declare -a STATUSES=()
declare -a DIRS=()
declare -a MESSAGES=()

PASS_COUNT=0
FAIL_COUNT=0

find_project_dir() {
    local pkg_name="$1"
    local root="$2"

    # 嘗試 CI_ll_<pkgName> 格式
    local candidate="$root/CI_ll_${pkg_name}"
    if [[ -d "$candidate" ]]; then
        echo "$candidate"
        return
    fi

    # 嘗試直接匹配
    candidate="$root/$pkg_name"
    if [[ -d "$candidate" ]]; then
        echo "$candidate"
        return
    fi

    # 模糊搜索
    local found
    found=$(find "$root" -maxdepth 2 -type d -name "*${pkg_name}*" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
        return
    fi

    return 1
}

for pkg_name in "${ALL_PKG_NAMES[@]}"; do

    # 查找項目目錄
    project_dir=$(find_project_dir "$pkg_name" "$PROJECTS_ROOT") || true

    if [[ -z "$project_dir" ]]; then
        # 項目目錄不存在
        STATUSES+=("NOT_FOUND")
        DIRS+=("")
        MESSAGES+=("項目目錄不存在")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    # 檢查 pak_linyaps.sh 是否存在且可執行
    pak_script="$project_dir/pak_linyaps.sh"
    if [[ ! -f "$pak_script" ]]; then
        STATUSES+=("FAIL")
        DIRS+=("$project_dir")
        MESSAGES+=("缺少 pak_linyaps.sh")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if [[ ! -x "$pak_script" ]]; then
        # 不可執行，但可以修復（chmod +x），視為 WARN 級別
        chmod +x "$pak_script"
    fi

    # 全部通過
    STATUSES+=("PASS")
    DIRS+=("$project_dir")
    MESSAGES+=("")
    PASS_COUNT=$((PASS_COUNT + 1))
done

# ============================================================
# 步驟 3: 輸出終端表格
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║               linyaps 項目前置檢測結果                                  ║${NC}"
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
        PASS)
            printf "${GREEN}PASS    ${NC}| %-30s | %-50s | %s\n" "$pkg" "$dir" "✓"
            ;;
        FAIL)
            printf "${RED}FAIL    ${NC}| %-30s | %-50s | %s\n" "$pkg" "$dir" "✗ $msg"
            ;;
        NOT_FOUND)
            printf "${YELLOW}NOT_FOUND${NC}| %-30s | %-50s | %s\n" "$pkg" "-" "✗ $msg"
            ;;
    esac
done

echo ""
echo -e "總計: $TASK_COUNT | ${GREEN}通過: $PASS_COUNT${NC} | ${RED}失敗: $FAIL_COUNT${NC}"

# ============================================================
# 步驟 4: 輸出 JSON 結果文件
# ============================================================
if [[ -n "$OUTPUT_FILE" ]]; then
    # 構建 JSON 結果
    json_results="["
    for ((i = 0; i < TASK_COUNT; i++)); do
        if [[ $i -gt 0 ]]; then
            json_results+=","
        fi
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
    \"summary\": {
        \"total\": ${TASK_COUNT},
        \"passed\": ${PASS_COUNT},
        \"failed\": ${FAIL_COUNT}
    },
    \"results\": ${json_results}
}

with open('${OUTPUT_FILE}', 'w') as f:
    json.dump(result, f, indent=2, ensure_ascii=False)
" 2>/dev/null || {
        log_warn "JSON 結果文件寫入失敗: $OUTPUT_FILE"
    }

    log_info "結果已寫入: $OUTPUT_FILE"
fi

echo ""

# ============================================================
# 步驟 5: 退出碼
# ============================================================
if [[ $FAIL_COUNT -eq 0 ]]; then
    log_ok "所有項目驗證通過，可以進行打包！"
    exit 0
else
    log_err "存在 $FAIL_COUNT 個檢測未通過的項目，請先處理後再執行打包"
    exit 1
fi
