#!/bin/bash
# linyaps-packaging-runner 共享庫
# 被 skills/*/scripts/run_tasks.sh source 引入
#
# 使用方式（在子 SKILL 的 run_tasks.sh 中）：
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
#   source "$REPO_ROOT/scripts/common.sh"

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-}"

if [[ -z "$REPO_ROOT" ]]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SRC_DIR/.." && pwd)"
fi

ARCH_MAPPING_FILE="${REPO_ROOT}/skills/config/arch_mapping.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_python3() {
    if ! command -v python3 &>/dev/null; then
        log_err "需要 python3"
        exit 1
    fi
}

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
print('DATA_DIR=' + json.dumps(g.get('data_dir', '')))

tasks = data.get('tasks', [])
print('TASK_COUNT=' + str(len(tasks)))
for i, t in enumerate(tasks):
    print(f'TASK_{i}_PKGNAME=' + json.dumps(t.get('pkgName', '')))
    print(f'TASK_{i}_SRC_URL=' + json.dumps(t.get('src_url', '')))
    print(f'TASK_{i}_ARCH=' + json.dumps(t.get('arch', '')))
    print(f'TASK_{i}_ORIG_VERSION=' + json.dumps(t.get('orig_version', '')))
    print(f'TASK_{i}_TYPE=' + json.dumps(t.get('type', 'binary')))
    print(f'TASK_{i}_KIND=' + json.dumps(t.get('kind', '')))
    print(f'TASK_{i}_NAME=' + json.dumps(t.get('name', '')))
    print(f'TASK_{i}_COMMIT=' + json.dumps(t.get('commit', '')))
" "$1"
}

json_strip() {
    local val="$1"
    val="${val//\"/}"
    echo "$val"
}

init_directories() {
    mkdir -p "$SRC_DIR" "$OUTPUT_DIR"

    if [[ -n "$BUILD_TMP_DIR" ]]; then
        BUILD_TMP_DIR="$(cd "$BUILD_TMP_DIR" 2>/dev/null && pwd || mkdir -p "$BUILD_TMP_DIR" && cd "$BUILD_TMP_DIR" && pwd)"
        log_info "緩存目錄:   $BUILD_TMP_DIR"
    else
        BUILD_TMP_DIR="$(mktemp -d)"
        log_info "緩存目錄:   $BUILD_TMP_DIR (自動生成)"
    fi

    if [[ -n "$DATA_DIR" ]]; then
        DATA_DIR="$(cd "$DATA_DIR" 2>/dev/null && pwd || mkdir -p "$DATA_DIR" && cd "$DATA_DIR" && pwd)"
        log_info "數據目錄:   $DATA_DIR"
    fi
}

extract_version_from_url() {
    local url="$1"
    local pkg_name="$2"
    local config_file="${3:-${CONFIG_FILE:-}}"

    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        echo "$url" | grep -oP '\d+\.\d+\.\d+(?:\.\d+)?' | head -1
        return
    fi

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
" "$config_file" "$pkg_name" 2>/dev/null) || true

    if [[ -n "$regex" ]]; then
        local ver
        ver=$(echo "$url" | grep -oP "$regex" | head -1) || true
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return
        fi
    fi

    echo "$url" | grep -oP '\d+\.\d+\.\d+(?:\.\d+)?' | head -1
}

validate_arch_match() {
    local src_url="$1"
    local declared_arch="$2"
    local mapping_file="${3:-$ARCH_MAPPING_FILE}"
    local pkg_name="$4"

    if [[ ! -f "$mapping_file" ]]; then
        log_warn "架構映射表不存在: $mapping_file，跳過驗證"
        return 0
    fi

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

url_lower = url.lower()
for token, linyaps_arch in token_map.items():
    if token in url_lower:
        if linyaps_arch is None:
            matched_arches.add('__UNSUPPORTED__')
            unknown_tokens.append(token)
        else:
            matched_arches.add(linyaps_arch)

for p in patterns:
    m = re.search(p['pattern'], url, re.IGNORECASE)
    if m:
        for g in m.groups():
            if g:
                g_lower = g.lower()
                for map_key in p['map_to']:
                    if map_key.lower() == g_lower:
                        matched_arches.add(p['map_to'][map_key])
                        break

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
            return 0
            ;;
    esac
}

download_source() {
    local url="$1"
    local dest_dir="$2"
    local pkg_name="$3"

    local filename
    filename=$(basename "$url")

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
    if curl -L --progress-bar -o "$dest_path" "$url" >/dev/null; then
        log_ok "下載完成: $dest_path"
        echo "$dest_path"
    else
        log_err "下載失敗: $url"
        return 1
    fi
}

supports_build_tmp_dir() {
    local script_path="$1"
    grep -q 'build_tmp_dir' "$script_path" 2>/dev/null
}

find_project_dir() {
    local pkg_name="$1"
    local root="$2"

    local candidate="$root/CI_ll_${pkg_name}"
    if [[ -d "$candidate" && -f "$candidate/pak_linyaps.sh" ]]; then
        echo "$candidate"
        return
    fi

    candidate="$root/$pkg_name"
    if [[ -d "$candidate" && -f "$candidate/pak_linyaps.sh" ]]; then
        echo "$candidate"
        return
    fi

    local found
    found=$(find "$root" -maxdepth 2 -type d -name "*${pkg_name}*" 2>/dev/null | head -1)
    if [[ -n "$found" && -f "$found/pak_linyaps.sh" ]]; then
        echo "$found"
        return
    fi

    return 1
}

find_source_project_dir() {
    local pkg_name="$1"
    local root="$2"

    local candidate="$root/CI_ll_${pkg_name}"
    if [[ -d "$candidate" && -f "$candidate/linglong.yaml" ]]; then
        echo "$candidate"
        return
    fi

    candidate="$root/$pkg_name"
    if [[ -d "$candidate" && -f "$candidate/linglong.yaml" ]]; then
        echo "$candidate"
        return
    fi

    local found
    found=$(find "$root" -maxdepth 2 -type d -name "*${pkg_name}*" 2>/dev/null | head -1)
    if [[ -n "$found" && -f "$found/linglong.yaml" ]]; then
        echo "$found"
        return
    fi

    return 1
}

print_results_summary() {
    local task_count="$1"
    local success_count="$2"
    local fail_count="$3"
    shift 3
    local -a results=("$@")

    echo ""
    log_info "=========================================="
    log_info "打包結果統計"
    log_info "=========================================="
    log_info "總計: $task_count | ${GREEN}成功: $success_count${NC} | ${RED}失敗: $fail_count${NC}"
    echo ""

    for r in "${results[@]}"; do
        if [[ "$r" == *": 成功"* ]]; then
            echo -e "  ${GREEN}✓${NC} $r"
        else
            echo -e "  ${RED}✗${NC} $r"
        fi
    done

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        log_ok "所有任務打包成功！"
    else
        log_warn "$fail_count 個任務失敗，請檢查日誌"
    fi
}
