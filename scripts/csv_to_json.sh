#!/bin/bash
# linyaps 任務導入工具：支持 CSV 和 JSON 格式
# 用法: ./csv_to_json.sh <task.csv|task.json> [options]
#
# CSV 欄位映射:
#   包名 → pkgName | 下載地址 → src_url | 架構 → arch | 版本 → orig_version
#
# 選項:
#   --projects_root=<path>   項目根目錄 (預設: ./projects)
#   --output_dir=<path>      輸出目錄 (預設: ./output)
#   --build_tmp_dir=<path>   構建緩存目錄 (預設: 自動生成)
#   --src_dir=<path>         原始資源目錄 (預設: ./src)
#   --config=<config.json>   JSON 配置文件 (僅含 global 部分)
#   --output=<file.json>     輸出 JSON 文件
#   --dry-run                僅生成 JSON，不執行打包
#   --help                   顯示說明

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 顏色定義
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================================
# 預設配置
# ============================================================
DEFAULT_PROJECTS_ROOT="./projects"
DEFAULT_OUTPUT_DIR="./output"
DEFAULT_BUILD_TMP_DIR=""
DEFAULT_SRC_DIR="./src"

# ============================================================
# 使用說明
# ============================================================
show_help() {
    cat <<'HELP'
linyaps 任務導入工具：支持 CSV 和 JSON 格式

用法:
  ./csv_to_json.sh <task.csv|task.json> [options]

CSV 欄位映射:
  記錄ID      (忽略，僅供參考)
  包名        → pkgName
  架構        → arch
  版本        → orig_version (可選，為空時從 URL 自動提取)
  網站地址    (忽略，僅供參考)
  下載地址    → src_url

選項:
  --projects_root=<path>   項目根目錄 (預設: ./projects)
  --output_dir=<path>      輸出目錄 (預設: ./output)
  --build_tmp_dir=<path>   構建緩存目錄 (預設: 自動生成)
  --src_dir=<path>         原始資源目錄 (預設: ./src)
  --config=<config.json>   JSON 配置文件 (僅含 global 部分)
  --output=<file.json>     輸出 JSON 文件 (預設: /tmp/linyaps_tasks_<timestamp>.json)
  --dry-run                僅生成 JSON，不執行打包
  --help                   顯示此說明

範例:
  # 使用 CSV 導入任務，使用預設配置
  ./csv_to_json.sh tasks.csv

  # 指定項目根目錄
  ./csv_to_json.sh tasks.csv --projects_root=/path/to/projects

  # 僅生成 JSON 不執行
  ./csv_to_json.sh tasks.csv --dry-run

  # 使用 JSON 配置文件
  ./csv_to_json.sh tasks.csv --config=global_config.json

  # 直接使用 JSON 任務文件 (向後兼容)
  ./csv_to_json.sh task.json
HELP
}

# ============================================================
# 解析命令行參數
# ============================================================
INPUT_FILE=""
PROJECTS_ROOT="$DEFAULT_PROJECTS_ROOT"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
BUILD_TMP_DIR="$DEFAULT_BUILD_TMP_DIR"
SRC_DIR="$DEFAULT_SRC_DIR"
CONFIG_FILE=""
OUTPUT_JSON=""
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --projects_root=*)
                PROJECTS_ROOT="${1#*=}"
                ;;
            --output_dir=*)
                OUTPUT_DIR="${1#*=}"
                ;;
            --build_tmp_dir=*)
                BUILD_TMP_DIR="${1#*=}"
                ;;
            --src_dir=*)
                SRC_DIR="${1#*=}"
                ;;
            --config=*)
                CONFIG_FILE="${1#*=}"
                ;;
            --output=*)
                OUTPUT_JSON="${1#*=}"
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            -*)
                log_err "未知選項: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$INPUT_FILE" ]]; then
                    INPUT_FILE="$1"
                else
                    log_err "過多參數: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$INPUT_FILE" ]]; then
        log_err "缺少輸入文件"
        show_help
        exit 1
    fi

    if [[ ! -f "$INPUT_FILE" ]]; then
        log_err "文件不存在: $INPUT_FILE"
        exit 1
    fi
}

# ============================================================
# 檢測文件類型
# ============================================================
detect_file_type() {
    local file="$1"
    local ext="${file##*.}"
    case "${ext,,}" in
        csv)  echo "csv" ;;
        json) echo "json" ;;
        *)
            # 嘗試從內容檢測
            local first_line
            first_line=$(head -1 "$file" | tr -d '[:space:]')
            if [[ "$first_line" == "{"* ]]; then
                echo "json"
            else
                echo "csv"
            fi
            ;;
    esac
}

# ============================================================
# 從 JSON 配置文件讀取 global 設定
# ============================================================
load_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_err "配置文件不存在: $config_file"
        exit 1
    fi

    local result
    result=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
g = data.get('global', {})
print('PROJECTS_ROOT=' + json.dumps(g.get('projects_root', '')))
print('OUTPUT_DIR=' + json.dumps(g.get('output_dir', '')))
print('BUILD_TMP_DIR=' + json.dumps(g.get('build_tmp_dir', '')))
print('SRC_DIR=' + json.dumps(g.get('src_dir', '')))
" "$config_file" 2>/dev/null) || {
        log_err "配置文件格式錯誤: $config_file"
        exit 1
    }

    eval "$result"

    # 僅在配置文件有值時覆蓋預設值
    [[ -n "$PROJECTS_ROOT" && "$PROJECTS_ROOT" != '""' ]] || PROJECTS_ROOT="$DEFAULT_PROJECTS_ROOT"
    [[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != '""' ]] || OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
    [[ -n "$BUILD_TMP_DIR" && "$BUILD_TMP_DIR" != '""' ]] || BUILD_TMP_DIR="$DEFAULT_BUILD_TMP_DIR"
    [[ -n "$SRC_DIR" && "$SRC_DIR" != '""' ]] || SRC_DIR="$DEFAULT_SRC_DIR"
}

# ============================================================
# CSV 轉 JSON (使用 python 確保可靠解析)
# ============================================================
csv_to_json() {
    local csv_file="$1"
    local projects_root="$2"
    local output_dir="$3"
    local build_tmp_dir="$4"
    local src_dir="$5"

    python3 -c "
import csv, json, sys

csv_file = sys.argv[1]
projects_root = sys.argv[2]
output_dir = sys.argv[3]
build_tmp_dir = sys.argv[4]
src_dir = sys.argv[5]

# 讀取 CSV
rows = []
with open(csv_file, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        # 清理所有欄位的空白和 tab
        cleaned = {}
        for k, v in row.items():
            if k is not None:
                cleaned[k.strip()] = v.strip() if v else ''
        rows.append(cleaned)

# 驗證必要欄位 (支持簡體/繁體中文表頭)
col_aliases = {
    '包名': ['包名'],
    '下载地址': ['下载地址', '下載地址', 'download_url', 'src_url'],
    '架构': ['架构', '架構', 'arch'],
    '版本': ['版本', 'version'],
}
def find_col(row_keys, aliases):
    for alias in aliases:
        if alias in row_keys:
            return alias
    return None

header = list(rows[0].keys()) if rows else []
download_col = find_col(header, col_aliases['下载地址'])
arch_col = find_col(header, col_aliases['架构'])
pkg_col = find_col(header, col_aliases['包名'])

missing = []
if not pkg_col: missing.append('包名')
if not download_col: missing.append('下载地址')
if not arch_col: missing.append('架构')
if missing:
    print(f'錯誤: CSV 缺少必要欄位: {missing}', file=sys.stderr)
    print(f'實際欄位: {header}', file=sys.stderr)
    sys.exit(1)

version_col = find_col(header, col_aliases['版本'])

# 映射欄位
tasks = []
for row in rows:
    pkg_name = row.get(pkg_col, '').strip()
    src_url = row.get(download_col, '').strip()
    arch = row.get(arch_col, '').strip()
    orig_version = row.get(version_col, '').strip() if version_col else ''

    # 跳過空行或缺少必要欄位的行
    if not pkg_name or not src_url:
        continue

    task = {
        'pkgName': pkg_name,
        'src_url': src_url,
        'arch': arch,
    }
    # 僅在有版本號時加入
    if orig_version:
        task['orig_version'] = orig_version
    else:
        task['orig_version'] = ''

    tasks.append(task)

# 組裝完整 JSON
result = {
    'global': {
        'projects_root': projects_root,
        'output_dir': output_dir,
        'build_tmp_dir': build_tmp_dir,
        'src_dir': src_dir
    },
    'tasks': tasks
}

print(json.dumps(result, indent=2, ensure_ascii=False))
" "$csv_file" "$projects_root" "$output_dir" "$build_tmp_dir" "$src_dir"
}

# ============================================================
# 直接傳遞 JSON 任務文件 (向後兼容)
# ============================================================
pass_through_json() {
    local json_file="$1"
    log_info "檢測到 JSON 格式，直接傳遞給 run_tasks.sh"
    exec "${SCRIPT_DIR}/run_tasks.sh" "$json_file"
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    # 檢測文件類型
    local file_type
    file_type=$(detect_file_type "$INPUT_FILE")
    log_info "文件類型: $file_type"
    log_info "輸入文件: $INPUT_FILE"

    # JSON 文件直接傳遞
    if [[ "$file_type" == "json" ]]; then
        pass_through_json "$INPUT_FILE"
        return
    fi

    # === CSV 處理流程 ===

    # 如果指定了配置文件，載入配置
    if [[ -n "$CONFIG_FILE" ]]; then
        log_info "載入配置文件: $CONFIG_FILE"
        load_config "$CONFIG_FILE"
    fi

    log_info "配置:"
    log_info "  projects_root: $PROJECTS_ROOT"
    log_info "  output_dir:    $OUTPUT_DIR"
    log_info "  build_tmp_dir: ${BUILD_TMP_DIR:-<自動生成>}"
    log_info "  src_dir:       $SRC_DIR"

    # CSV 轉 JSON
    log_info "解析 CSV 文件..."
    local json_content
    json_content=$(csv_to_json "$INPUT_FILE" "$PROJECTS_ROOT" "$OUTPUT_DIR" "$BUILD_TMP_DIR" "$SRC_DIR") || {
        log_err "CSV 解析失敗"
        exit 1
    }

    # 統計任務數
    local task_count
    task_count=$(echo "$json_content" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('tasks',[])))")
    log_ok "解析完成，共 $task_count 個任務"

    # 確定輸出文件路徑
    if [[ -z "$OUTPUT_JSON" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d%H%M%S)
        OUTPUT_JSON="/tmp/linyaps_tasks_${timestamp}.json"
    fi

    # 寫入 JSON 文件
    echo "$json_content" > "$OUTPUT_JSON"
    log_ok "已生成 JSON 文件: $OUTPUT_JSON"

    # dry-run 模式：僅輸出 JSON 內容
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "=== dry-run 模式：生成的 JSON 內容 ==="
        echo "$json_content"
        return
    fi

    # 執行打包任務
    log_info "調用 run_tasks.sh 執行打包..."
    exec "${SCRIPT_DIR}/run_tasks.sh" "$OUTPUT_JSON"
}

main "$@"
