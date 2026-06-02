#!/bin/bash
# linyaps 便捷打包腳本自動執行器
# 用法: ./run_tasks.sh <task.json>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_FILE="${1:?用法: $0 <task.json>}"
ARCH_MAPPING_FILE="${SCRIPT_DIR}/../arch_mapping.json"

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================
# 步驟 1: 解析 JSON（使用 python，確保可用）
# ============================================================
if ! command -v python3 &>/dev/null; then
    log_err "需要 python3 來解析 JSON"
    exit 1
fi

parse_json() {
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

g = data.get('global', {})
print('PROJECTS_ROOT=' + json.dumps(g.get('projects_root', '')))
print('OUTPUT_DIR=' + json.dumps(g.get('output_dir', './output')))
print('BUILD_TMP_DIR=' + json.dumps(g.get('build_tmp_dir', '')))
print('SRC_DIR=' + json.dumps(g.get('src_dir', './src')))

tasks = data.get('tasks', [])
print('TASK_COUNT=' + str(len(tasks)))
for i, t in enumerate(tasks):
    print(f'TASK_{i}_PKGNAME=' + json.dumps(t.get('pkgName', '')))
    print(f'TASK_{i}_SRC_URL=' + json.dumps(t.get('src_url', '')))
    print(f'TASK_{i}_ARCH=' + json.dumps(t.get('arch', '')))
    print(f'TASK_{i}_ORIG_VERSION=' + json.dumps(t.get('orig_version', '')))
" "$1"
}

eval "$(parse_json "$TASK_FILE")"

if [[ -z "$PROJECTS_ROOT" || "$PROJECTS_ROOT" == '""' ]]; then
    log_err "JSON 中缺少 global.projects_root"
    exit 1
fi

# 轉換為絕對路徑
PROJECTS_ROOT="$(cd "$PROJECTS_ROOT" 2>/dev/null && pwd || echo "$PROJECTS_ROOT")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" || OUTPUT_DIR="./output"
SRC_DIR="$(cd "$(dirname "$SRC_DIR")" 2>/dev/null && pwd)/$(basename "$SRC_DIR")" || SRC_DIR="./src"

# 去除 JSON 引號
OUTPUT_DIR="${OUTPUT_DIR//\"/}"
SRC_DIR="${SRC_DIR//\"/}"
BUILD_TMP_DIR="${BUILD_TMP_DIR//\"/}"

log_info "項目根目錄: $PROJECTS_ROOT"
log_info "輸出目錄:   $OUTPUT_DIR"
log_info "資源目錄:   $SRC_DIR"

# ============================================================
# 步驟 2: 初始化目錄
# ============================================================
mkdir -p "$SRC_DIR" "$OUTPUT_DIR"

if [[ -n "$BUILD_TMP_DIR" ]]; then
    BUILD_TMP_DIR="$(cd "$BUILD_TMP_DIR" 2>/dev/null && pwd || mkdir -p "$BUILD_TMP_DIR" && cd "$BUILD_TMP_DIR" && pwd)"
    log_info "緩存目錄:   $BUILD_TMP_DIR"
else
    BUILD_TMP_DIR="$(mktemp -d)"
    log_info "緩存目錄:   $BUILD_TMP_DIR (自動生成)"
fi

# ============================================================
# 步驟 3: 從 URL 提取版本號的輔助函數
# ============================================================
extract_version_from_url() {
    local url="$1"
    local pkg_name="$2"

    # 嘗試從 JSON 的 version_extract_examples 中提取 regex
    local regex
    regex=$(python3 -c "
import json, re, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for ex in data.get('version_extract_examples', []):
    pat = ex.get('url_pattern', '')
    if any(kw in pat.lower() for kw in sys.argv[2].lower().split('.')):
        print(ex.get('extract_regex', ''))
        break
" "$TASK_FILE" "$pkg_name" 2>/dev/null) || true

    if [[ -n "$regex" ]]; then
        local ver
        ver=$(echo "$url" | grep -oP "$regex" | head -1) || true
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return
        fi
    fi

    # 通用提取：匹配連續的版本號模式 x.y.z 或 x.y.z.w
    echo "$url" | grep -oP '\d+\.\d+\.\d+(?:\.\d+)?' | head -1
}

# ============================================================
# 步驟 3b: 架構匹配驗證
# ============================================================
validate_arch_match() {
    local src_url="$1"
    local declared_arch="$2"
    local mapping_file="$3"
    local pkg_name="$4"

    if [[ ! -f "$mapping_file" ]]; then
        log_warn "架構映射表不存在: $mapping_file，跳過驗證"
        return 0
    fi

    # 使用 python 進行映射表比對
    local result
    result=$(python3 -c "
import json, re, sys

url = sys.argv[1]
declared = sys.argv[2]
pkg = sys.argv[4]

with open(sys.argv[3]) as f:
    mapping = json.load(f)

token_map = mapping.get('token_map', {})
patterns = mapping.get('regex_patterns', [])

matched_arches = set()
unknown_tokens = []

# 1. Token 匹配：掃描 URL 中出現的所有已知 token
url_lower = url.lower()
for token, linyaps_arch in token_map.items():
    if token in url_lower:
        if linyaps_arch is None:
            # 已知但非支援架構（如 i386）→ 記為不匹配
            matched_arches.add('__UNSUPPORTED__')
            unknown_tokens.append(token)
        else:
            matched_arches.add(linyaps_arch)

# 2. Regex pattern 匹配
for p in patterns:
    m = re.search(p['pattern'], url, re.IGNORECASE)
    if m:
        for g in m.groups():
            if g:
                g_lower = g.lower()
                # 找到 map_to 中 key 不區分大小寫的匹配
                for map_key in p['map_to']:
                    if map_key.lower() == g_lower:
                        matched_arches.add(p['map_to'][map_key])
                        break

# 判斷結果
if not matched_arches:
    print('STATUS=UNKNOWN')
    print('URL_ARCHES=')
elif '__UNSUPPORTED__' in matched_arches and all(a == '__UNSUPPORTED__' for a in matched_arches):
    print('STATUS=MISMATCH')
    print('URL_ARCHES=' + ','.join(sorted(unknown_tokens)))
else:
    matched_arches.discard('__UNSUPPORTED__')
    url_arches_str = ','.join(sorted(matched_arches))
    if declared in matched_arches:
        print('STATUS=MATCH')
        print('URL_ARCHES=' + url_arches_str)
    else:
        print('STATUS=MISMATCH')
        print('URL_ARCHES=' + url_arches_str)
" "$src_url" "$declared_arch" "$mapping_file" "$pkg_name" 2>/dev/null) || {
        log_warn "架構驗證執行失敗（python 錯誤），跳過驗證"
        return 0
    }

    eval "$result"

    case "$STATUS" in
        MATCH)
            log_ok "架構驗證通過: URL 含架構(${URL_ARCHES}) → 宣告 arch(${declared_arch}) ✓"
            return 0
            ;;
        MISMATCH)
            log_err "架構不匹配: URL 含架構(${URL_ARCHES})，但宣告 arch 為 ${declared_arch}"
            return 1
            ;;
        UNKNOWN)
            log_warn "架構無法自動識別，請 LLM 分析:"
            echo ""
            echo "  ╔══════════════════════════════════════════════╗"
            echo "  ║        LLM 架構分析請求                       ║"
            echo "  ╠══════════════════════════════════════════════╣"
            echo "  ║  包名:      ${pkg_name}"
            echo "  ║  src_url:   ${src_url}"
            echo "  ║  宣告 arch: ${declared_arch}"
            echo "  ║                                              ║"
            echo "  ║  請分析 src_url 中的架構特徵，與宣告 arch    ║"
            echo "  ║  是否匹配。若不匹配請修正 tasks[].arch。     ║"
            echo "  ╚══════════════════════════════════════════════╝"
            echo ""
            # UNKNOWN 狀態不阻斷，繼續執行
            return 0
            ;;
    esac
}

# ============================================================
# 步驟 4: 下載資源
# ============================================================
download_source() {
    local url="$1"
    local dest_dir="$2"
    local pkg_name="$3"

    # 從 URL 推斷文件名
    local filename
    filename=$(basename "$url")

    # 處理可能的重定向（如 VS Code update URL）
    if [[ "$url" == *"/latest/"* ]]; then
        log_info "檢測到重定向 URL，嘗試解析實際下載地址..."
        local redirect_url
        redirect_url=$(curl -sIL "$url" 2>/dev/null | grep -i '^location:' | tail -1 | awk '{print $2}' | tr -d '\r')
        if [[ -n "$redirect_url" ]]; then
            url="$redirect_url"
            filename=$(basename "$url")
            log_info "實際下載地址: $url"
        fi
    fi

    local dest_path="$dest_dir/$filename"

    if [[ -f "$dest_path" ]]; then
        log_ok "資源已存在: $dest_path"
        echo "$dest_path"
        return
    fi

    log_info "下載: $url"
    if curl -L --progress-bar -o "$dest_path" "$url"; then
        log_ok "下載完成: $dest_path"
        echo "$dest_path"
    else
        log_err "下載失敗: $url"
        return 1
    fi
}

# ============================================================
# 步驟 5: 檢測 pak_linyaps.sh 是否支援 --build_tmp_dir
# ============================================================
supports_build_tmp_dir() {
    local script_path="$1"
    grep -q 'build_tmp_dir' "$script_path" 2>/dev/null
}

# ============================================================
# 步驟 6: 定位項目目錄
# ============================================================
find_project_dir() {
    local pkg_name="$1"
    local root="$2"

    # 嘗試 CI_ll_<pkgName> 格式
    local candidate="$root/CI_ll_${pkg_name}"
    if [[ -d "$candidate" && -f "$candidate/pak_linyaps.sh" ]]; then
        echo "$candidate"
        return
    fi

    # 嘗試直接匹配
    candidate="$root/$pkg_name"
    if [[ -d "$candidate" && -f "$candidate/pak_linyaps.sh" ]]; then
        echo "$candidate"
        return
    fi

    # 模糊搜索
    local found
    found=$(find "$root" -maxdepth 2 -type d -name "*${pkg_name}*" 2>/dev/null | head -1)
    if [[ -n "$found" && -f "$found/pak_linyaps.sh" ]]; then
        echo "$found"
        return
    fi

    return 1
}

# ============================================================
# 步驟 7: 執行打包任務
# ============================================================
SUCCESS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

run_task() {
    local idx="$1"
    local pkg_name_var="TASK_${idx}_PKGNAME"
    local src_url_var="TASK_${idx}_SRC_URL"
    local arch_var="TASK_${idx}_ARCH"
    local ver_var="TASK_${idx}_ORIG_VERSION"

    local pkg_name="${!pkg_name_var}"
    local src_url="${!src_url_var}"
    local arch="${!arch_var}"
    local orig_version="${!ver_var}"

    # 去除 JSON 引號
    pkg_name="${pkg_name//\"/}"
    src_url="${src_url//\"/}"
    arch="${arch//\"/}"
    orig_version="${orig_version//\"/}"

    log_info "=========================================="
    log_info "任務 [$((idx+1))/$TASK_COUNT]: $pkg_name"
    log_info "=========================================="

    # 提取版本號
    if [[ -z "$orig_version" ]]; then
        orig_version=$(extract_version_from_url "$src_url" "$pkg_name")
        if [[ -n "$orig_version" ]]; then
            log_info "從 URL 提取版本號: $orig_version"
        else
            log_err "無法從 URL 提取版本號: $src_url"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            RESULTS+=("$pkg_name: 失敗 (無法提取版本號)")
            return
        fi
    fi

    # 架構驗證
    if ! validate_arch_match "$src_url" "$arch" "$ARCH_MAPPING_FILE" "$pkg_name"; then
        log_err "架構不匹配，跳過任務 $pkg_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (架構不匹配: URL 架構 vs 宣告 arch=${arch})")
        return
    fi

    # 下載資源
    local src_path
    src_path=$(download_source "$src_url" "$SRC_DIR" "$pkg_name") || {
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (下載失敗)")
        return
    }

    # 定位項目
    local project_dir
    project_dir=$(find_project_dir "$pkg_name" "$PROJECTS_ROOT") || {
        log_err "找不到項目目錄: $pkg_name (在 $PROJECTS_ROOT 下)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (找不到項目目錄)")
        return
    }
    log_ok "項目目錄: $project_dir"

    local pak_script="$project_dir/pak_linyaps.sh"
    chmod +x "$pak_script"

    # 檢測 --build_tmp_dir 支援
    local build_tmp_arg=""
    if supports_build_tmp_dir "$pak_script"; then
        build_tmp_arg="--build_tmp_dir=${BUILD_TMP_DIR}"
        log_info "檢測到 --build_tmp_dir 支援"
    else
        log_info "該項目不支援 --build_tmp_dir，跳過該參數"
    fi

    # 生成命令
    local cmd="./pak_linyaps.sh \
  --linyaps_arch=${arch} \
  --origin_version=${orig_version} \
  --src_path=\"${src_path}\" \
  --output_dir=\"${OUTPUT_DIR}\""
    if [[ -n "$build_tmp_arg" ]]; then
        cmd="$cmd \\
  ${build_tmp_arg}"
    fi

    log_info "執行命令:"
    echo "$cmd"
    echo ""

    # 執行打包（後台執行，捕獲輸出）
    local log_file="$OUTPUT_DIR/${pkg_name}.log"
    local start_time
    start_time=$(date +%s)

    if (cd "$project_dir" && eval "$cmd" > "$log_file" 2>&1); then
        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log_ok "$pkg_name 打包成功 (耗時 ${elapsed}s)"
        log_info "最後輸出:"
        tail -5 "$log_file" | sed 's/^/  /'
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        RESULTS+=("$pkg_name: 成功 (${elapsed}s)")
    else
        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log_err "$pkg_name 打包失敗 (耗時 ${elapsed}s)"
        log_err "錯誤輸出:"
        tail -10 "$log_file" | sed 's/^/  /'
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (詳見 $log_file)")
    fi
    echo ""
}

# ============================================================
# 步驟 8: 依次執行所有任務
# ============================================================
log_info "共 $TASK_COUNT 個打包任務"
echo ""

for ((i = 0; i < TASK_COUNT; i++)); do
    run_task "$i"
done

# ============================================================
# 步驟 9: 輸出結果統計
# ============================================================
echo ""
log_info "=========================================="
log_info "打包結果統計"
log_info "=========================================="
log_info "總計: $TASK_COUNT | ${GREEN}成功: $SUCCESS_COUNT${NC} | ${RED}失敗: $FAIL_COUNT${NC}"
echo ""

for r in "${RESULTS[@]}"; do
    if [[ "$r" == *": 成功"* ]]; then
        echo -e "  ${GREEN}✓${NC} $r"
    else
        echo -e "  ${RED}✗${NC} $r"
    fi
done

echo ""
if [[ $FAIL_COUNT -eq 0 ]]; then
    log_ok "所有任務打包成功！"
else
    log_warn "$FAIL_COUNT 個任務失敗，請檢查日誌"
fi
