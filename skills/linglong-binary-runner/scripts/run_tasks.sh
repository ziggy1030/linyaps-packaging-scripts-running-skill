#!/bin/bash
# linyaps binary 打包執行器 — 透過 pak_linyaps.sh 執行二進制打包
# 用法: ./run_tasks.sh <task.json>
# 依賴: scripts/common.sh（共享庫）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASK_FILE="${1:?用法: $0 <task.json>}"
CONFIG_FILE="${REPO_ROOT}/agent-config.json"

source "$REPO_ROOT/scripts/common.sh"

check_python3

eval "$(parse_json "$TASK_FILE")"

if [[ -z "$PROJECTS_ROOT" || "$PROJECTS_ROOT" == '""' ]]; then
    log_err "JSON 中缺少 global.projects_root"
    exit 1
fi

PROJECTS_ROOT="$(cd "$PROJECTS_ROOT" 2>/dev/null && pwd || echo "$PROJECTS_ROOT")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")" || OUTPUT_DIR="./output"
SRC_DIR="$(cd "$(dirname "$SRC_DIR")" 2>/dev/null && pwd)/$(basename "$SRC_DIR")" || SRC_DIR="./src"

OUTPUT_DIR=$(json_strip "$OUTPUT_DIR")
SRC_DIR=$(json_strip "$SRC_DIR")
BUILD_TMP_DIR=$(json_strip "$BUILD_TMP_DIR")

log_info "項目根目錄: $PROJECTS_ROOT"
log_info "輸出目錄:   $OUTPUT_DIR"
log_info "資源目錄:   $SRC_DIR"

init_directories

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

    pkg_name=$(json_strip "$pkg_name")
    src_url=$(json_strip "$src_url")
    arch=$(json_strip "$arch")
    orig_version=$(json_strip "$orig_version")

    log_info "=========================================="
    log_info "任務 [$((idx+1))/$TASK_COUNT]: $pkg_name"
    log_info "=========================================="

    if [[ -z "$orig_version" ]]; then
        orig_version=$(extract_version_from_url "$src_url" "$pkg_name" "$CONFIG_FILE")
        if [[ -n "$orig_version" ]]; then
            log_info "從 URL 提取版本號: $orig_version"
        else
            log_err "無法從 URL 提取版本號: $src_url"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            RESULTS+=("$pkg_name: 失敗 (無法提取版本號)")
            return
        fi
    fi

    if ! validate_arch_match "$src_url" "$arch" "$ARCH_MAPPING_FILE" "$pkg_name"; then
        log_err "架構不匹配，跳過任務 $pkg_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (架構不匹配: URL 架構 vs 宣告 arch=${arch})")
        return
    fi

    local src_path
    src_path=$(download_source "$src_url" "$SRC_DIR" "$pkg_name") || {
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (下載失敗)")
        return
    }

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

    local task_build_tmp_dir="${BUILD_TMP_DIR}/${pkg_name}"
    mkdir -p "$task_build_tmp_dir"
    log_info "任務緩存目錄: $task_build_tmp_dir"

    local build_tmp_arg=""
    if supports_build_tmp_dir "$pak_script"; then
        build_tmp_arg="--build_tmp_dir=${task_build_tmp_dir}"
        log_info "檢測到 --build_tmp_dir 支援"
    else
        log_info "該項目不支援 --build_tmp_dir，跳過該參數"
    fi

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

log_info "共 $TASK_COUNT 個 binary 打包任務"
echo ""

for ((i = 0; i < TASK_COUNT; i++)); do
    run_task "$i"
done

print_results_summary "$TASK_COUNT" "$SUCCESS_COUNT" "$FAIL_COUNT" "${RESULTS[@]}"
