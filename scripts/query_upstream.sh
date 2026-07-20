#!/bin/bash
# 上游信息查詢腳本 — query_upstream.sh
# 根據 pkgName 從上游數據庫 API 查詢最新版本、下載地址、架構等信息
# 輸出兼容 run_tasks.sh 的完整任務 JSON
#
# 用法:
#   單包查詢:  ./scripts/query_upstream.sh --pkg-name=net.kuribo64.melonDS
#   批量查詢:  ./scripts/query_upstream.sh --task-file=tasks.json
#   管道輸入:  cat pkglist.txt | ./scripts/query_upstream.sh
#   完整輸出:  ./scripts/query_upstream.sh --pkg-name=xxx --global-config=cfg.json --output=full.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 顏色定義
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { [[ "$QUIET" != "true" ]] && echo -e "${CYAN}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================
# 配置區域 — 可在此修改默認值
# ============================================================
DEFAULT_API_URL="https://n8n.cicd.getdeepin.org/webhook/1f678037-e7f2-484c-a28b-b5c233fde531"

# ============================================================
# 默認參數值
# ============================================================
API_URL="$DEFAULT_API_URL"
GLOBAL_CONFIG_FILE=""
OUTPUT_FILE=""
QUIET=false
INPUT_MODE=""
PKG_NAME=""
TASK_FILE=""
HAS_STDIN=false

# ============================================================
# 使用說明
# ============================================================
show_help() {
    cat <<'HELP'
上游信息查詢腳本 — 根據 pkgName 從上游 API 查詢最新版本/下載地址/架構

用法:
  # 單包查詢
  ./scripts/query_upstream.sh --pkg-name=<pkgName>

  # 批量查詢（從 JSON 或純文本文件讀取 pkgName 列表）
  ./scripts/query_upstream.sh --task-file=<tasks.json|pkglist.txt>

  # 管道輸入（每行一個包名）
  echo "net.kuribo64.melonDS" | ./scripts/query_upstream.sh

  # 指定 global 配置 + 輸出到文件
  ./scripts/query_upstream.sh --task-file=tasks.json \
    --global-config=agent-config.json --output=full-tasks.json

選項:
  --pkg-name=<name>      單個包名查詢（支援逗號分隔多個包名）
  --task-file=<file>     從文件讀取 pkgName 列表
                         支援 JSON（tasks[].pkgName）或純文本（一行一個包名）
  --global-config=<file> JSON 配置文件（含 global 子對象，如 agent-config.json）
  --output=<file>        輸出到文件（預設輸出到 stdout）
  --api-url=<url>        上游查詢 API 地址（預設: 腳本內配置）
  --quiet                靜默模式，不輸出 INFO 日誌
  --help                 顯示此說明

輸出格式（JSON，兼容 run_tasks.sh）:
  {
    "global": { "projects_root": "...", "output_dir": "..." },
    "tasks": [
      { "pkgName": "...", "src_url": "...", "arch": "...", "orig_version": "..." }
    ]
  }

API 返回字段映射:
  appid         → pkgName
  download_url  → src_url
  version       → orig_version
  arch          → arch
HELP
    exit 0
}

# ============================================================
# 參數解析
# ============================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pkg-name=*)
            PKG_NAME="${1#*=}"
            INPUT_MODE="pkg_name"
            shift
            ;;
        --task-file=*)
            TASK_FILE="${1#*=}"
            INPUT_MODE="task_file"
            shift
            ;;
        --global-config=*)
            GLOBAL_CONFIG_FILE="${1#*=}"
            shift
            ;;
        --output=*)
            OUTPUT_FILE="${1#*=}"
            shift
            ;;
        --api-url=*)
            API_URL="${1#*=}"
            shift
            ;;
        --quiet)
            QUIET=true
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
# 檢查依賴
# ============================================================
if ! command -v python3 &>/dev/null; then
    log_err "需要 python3"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    log_err "需要 curl"
    exit 1
fi

# ============================================================
# 步驟 1: 收集包名列表
# ============================================================
PKG_NAMES=()

collect_from_stdin() {
    # 檢查是否有管道輸入
    if [[ ! -t 0 ]]; then
        while IFS= read -r line; do
            line="$(echo "$line" | xargs)"  # trim
            [[ -n "$line" ]] && PKG_NAMES+=("$line")
        done
        HAS_STDIN=true
    fi
}

case "$INPUT_MODE" in
    pkg_name)
        # 支援逗號分隔
        IFS=',' read -ra ADDR <<< "$PKG_NAME"
        for name in "${ADDR[@]}"; do
            name="$(echo "$name" | xargs)"
            [[ -n "$name" ]] && PKG_NAMES+=("$name")
        done
        ;;
    task_file)
        if [[ ! -f "$TASK_FILE" ]]; then
            log_err "任務文件不存在: $TASK_FILE"
            exit 1
        fi
        # 交給 Python 解析（JSON 或純文本）
        # 先將文件內容傳給 Python 判斷
        ;;
    "")
        # 無明確模式 → 嘗試 stdin
        collect_from_stdin
        if [[ "$HAS_STDIN" != "true" ]]; then
            log_err "請指定輸入: --pkg-name, --task-file, 或通過管道傳入包名"
            log_info "使用 --help 查看說明"
            exit 1
        fi
        ;;
esac

# ============================================================
# 步驟 2: 構建 Python 查詢腳本並執行
# ============================================================
# 使用 Python 處理：
#   - JSON 解析（task-file 可能是 JSON 或純文本）
#   - 調用上游 API 查詢
#   - 合併 global 配置
#   - 輸出最終 JSON
#
# 輸出寫入臨時文件，避免管道問題和重複執行

TEMP_OUTPUT=$(mktemp /tmp/query_upstream.XXXXXX.json)
trap 'rm -f "$TEMP_OUTPUT"' EXIT

python3 - "$API_URL" "$GLOBAL_CONFIG_FILE" "$INPUT_MODE" "$TASK_FILE" "${PKG_NAMES[@]}" << 'PYEOF' > "$TEMP_OUTPUT"
import json
import sys
import urllib.request
import urllib.parse
import os

api_url_base = sys.argv[1]
global_config_file = sys.argv[2]
input_mode = sys.argv[3]
task_file_path = sys.argv[4] if input_mode == "task_file" else None
pkg_names = sys.argv[5:] if len(sys.argv) > 5 else []

# ----------------------------------------------------------
# 步驟 1a: 若為 task_file 模式，從文件中提取 pkgName
# ----------------------------------------------------------
if input_mode == "task_file" and task_file_path:
    content = open(task_file_path, 'r', encoding='utf-8').read().strip()

    if content.startswith('{') or content.startswith('['):
        # JSON 格式
        data = json.loads(content)
        if isinstance(data, dict) and 'tasks' in data:
            # { "global": {...}, "tasks": [...], ... }
            # 若未指定 --global-config，從文件中提取 global
            if not global_config_file and 'global' in data:
                global_config_file = task_file_path  # 標記後續從此文件讀取

            extracted = []
            for t in data['tasks']:
                n = t.get('pkgName', '').strip()
                if n:
                    extracted.append(n)

            # 如果文件中已包含完整信息（有 src_url），直接透傳
            has_full_info = any(
                t.get('src_url') and t.get('src_url', '').strip()
                for t in data['tasks']
            )
            if has_full_info:
                # 已是完整任務 → 直接輸出（跳過 API 查詢）
                output = dict(data)
                if 'global' not in output:
                    output['global'] = {}
                print(json.dumps(output, indent=2, ensure_ascii=False))
                sys.exit(0)

            pkg_names = extracted
        elif isinstance(data, list):
            # 純陣列 [{ "pkgName": ... }] 或 ["pkg1", "pkg2"]
            for item in data:
                if isinstance(item, dict):
                    n = item.get('pkgName', '').strip()
                    if n:
                        pkg_names.append(n)
                elif isinstance(item, str):
                    item = item.strip()
                    if item:
                        pkg_names.append(item)
    else:
        # 純文本格式：一行一個包名
        for line in content.splitlines():
            line = line.strip()
            if line and not line.startswith('#'):
                pkg_names.append(line)

# ----------------------------------------------------------
# 步驟 1b: 載入 global 配置
# ----------------------------------------------------------
global_config = {}

if global_config_file and os.path.isfile(global_config_file):
    try:
        with open(global_config_file, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        # 支援 { "global": {...} } 或直接 { "projects_root": ... }
        if 'global' in cfg:
            global_config = cfg['global']
        else:
            global_config = cfg
    except Exception as e:
        print(f"[ERROR] 讀取 global 配置失敗: {e}", file=sys.stderr)

# ----------------------------------------------------------
# 步驟 2: 查詢上游 API
# ----------------------------------------------------------
if not pkg_names:
    print(json.dumps({
        "global": global_config,
        "tasks": [],
        "errors": [{"error": "未提供任何包名"}]
    }, indent=2, ensure_ascii=False))
    sys.exit(1)

tasks = []
errors = []
seen = set()

for name in pkg_names:
    if name in seen:
        continue
    seen.add(name)

    url = f"{api_url_base}?id={urllib.parse.quote(name)}"

    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode('utf-8')
            data = json.loads(raw)

        if data.get('success', False):
            tasks.append({
                'pkgName': data.get('appid', name),
                'src_url': data.get('download_url', ''),
                'arch': data.get('arch', ''),
                'orig_version': data.get('version', '')
            })
            print(f"[OK] {name}: version={data.get('version','?')} arch={data.get('arch','?')}", file=sys.stderr)
        else:
            err = {"pkgName": name, "error": "API 返回 success=false"}
            if 'html_url' in data:
                err['html_url'] = data['html_url']
            errors.append(err)
            print(f"[ERROR] {name}: API 返回 success=false", file=sys.stderr)
    except urllib.error.HTTPError as e:
        err_msg = f"HTTP {e.code}: {e.reason}"
        errors.append({"pkgName": name, "error": err_msg})
        print(f"[ERROR] {name}: {err_msg}", file=sys.stderr)
    except urllib.error.URLError as e:
        err_msg = f"連線失敗: {e.reason}"
        errors.append({"pkgName": name, "error": err_msg})
        print(f"[ERROR] {name}: {err_msg}", file=sys.stderr)
    except json.JSONDecodeError as e:
        err_msg = f"JSON 解析失敗: {e}"
        errors.append({"pkgName": name, "error": err_msg})
        print(f"[ERROR] {name}: {err_msg}", file=sys.stderr)
    except Exception as e:
        err_msg = str(e)
        errors.append({"pkgName": name, "error": err_msg})
        print(f"[ERROR] {name}: {err_msg}", file=sys.stderr)

# ----------------------------------------------------------
# 步驟 3: 構建輸出 JSON
# ----------------------------------------------------------
output = {
    "global": global_config,
    "tasks": tasks
}
if errors:
    output["errors"] = errors

print(json.dumps(output, indent=2, ensure_ascii=False))

# 退出碼：全部失敗則返回 1
if len(tasks) == 0 and len(errors) > 0:
    sys.exit(1)
else:
    sys.exit(0)
PYEOF

PY_EXIT_CODE=$?

# ============================================================
# 步驟 3: 輸出處理
# ============================================================
if [[ -n "$OUTPUT_FILE" ]]; then
    cp "$TEMP_OUTPUT" "$OUTPUT_FILE"
    log_ok "輸出已寫入: $OUTPUT_FILE"
fi

# 未指定輸出文件時，輸出到 stdout
if [[ -z "$OUTPUT_FILE" ]]; then
    cat "$TEMP_OUTPUT"
fi

exit $PY_EXIT_CODE