#!/bin/bash
# linyaps source 打包執行器 — 透過 ll-builder 執行源碼編譯打包
# 用法: ./run_tasks.sh <task.json> [--agent-config-path=<path>]
# 依賴: scripts/common.sh（共享庫）, download-and-checksum.sh, update-linglong-yaml.py, validate-linglong-yaml.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENT_CONFIG_PATH=""
TASK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-config-path=*) AGENT_CONFIG_PATH="${1#*=}"; shift ;;
    *) TASK_FILE="$1"; shift ;;
  esac
done

if [[ -z "$TASK_FILE" ]]; then
  echo "用法: $0 <task.json> [--agent-config-path=<path>]" >&2
  exit 1
fi

CONFIG_FILE="${AGENT_CONFIG_PATH:-${REPO_ROOT}/agent-config.json}"

source "$SCRIPT_DIR/common.sh"

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

run_source_task() {
    local idx="$1"
    local pkg_name_var="TASK_${idx}_PKGNAME"
    local src_url_var="TASK_${idx}_SRC_URL"
    local arch_var="TASK_${idx}_ARCH"
    local ver_var="TASK_${idx}_ORIG_VERSION"
    local kind_var="TASK_${idx}_KIND"
    local name_var="TASK_${idx}_NAME"
    local commit_var="TASK_${idx}_COMMIT"

    local pkg_name="${!pkg_name_var}"
    local src_url="${!src_url_var}"
    local arch="${!arch_var}"
    local orig_version="${!ver_var}"
    local kind="${!kind_var}"
    local sname="${!name_var}"
    local commit="${!commit_var}"

    pkg_name=$(json_strip "$pkg_name")
    src_url=$(json_strip "$src_url")
    arch=$(json_strip "$arch")
    orig_version=$(json_strip "$orig_version")
    kind=$(json_strip "$kind")
    sname=$(json_strip "$sname")
    commit=$(json_strip "$commit")

    [[ -z "$kind" ]] && kind="auto"

    log_info "=========================================="
    log_info "Source 任務 [$((idx+1))/$TASK_COUNT]: $pkg_name (kind=$kind)"
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

    local project_dir
    project_dir=$(find_source_project_dir "$pkg_name" "$PROJECTS_ROOT") || {
        log_err "找不到項目目錄: $pkg_name (在 $PROJECTS_ROOT 下)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (找不到項目目錄)")
        return
    }
    log_ok "項目目錄: $project_dir"

    local missing_deps=false
    if ! command -v ll-builder &>/dev/null; then
        log_err "缺少 ll-builder 命令（source 類型依賴），請安裝 linyaps-builder"
        missing_deps=true
    fi
    if ! python3 -c "import ruamel.yaml" 2>/dev/null; then
        log_err "缺少 python3-ruamel.yaml（source 類型依賴）"
        missing_deps=true
    fi
    if ! python3 -c "import yaml" 2>/dev/null; then
        log_err "缺少 python3-yaml（source 類型依賴）"
        missing_deps=true
    fi
    if $missing_deps; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (缺少依賴)")
        return
    fi

    local task_build_tmp_dir="${BUILD_TMP_DIR}/${pkg_name}"
    mkdir -p "$task_build_tmp_dir"
    log_info "任務緩存目錄: $task_build_tmp_dir"

    local start_time
    start_time=$(date +%s)
    local log_file="$OUTPUT_DIR/${pkg_name}.source.log"

    log_info "Step S-1: 驗證輸入 linglong.yaml..."
    if python3 "$SCRIPT_DIR/validate-linglong-yaml.py" "$project_dir/linglong.yaml" >> "$log_file" 2>&1; then
        log_ok "輸入驗證通過（無 sources 段）"
    else
        log_err "輸入驗證失敗: $project_dir/linglong.yaml"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (linglong.yaml 格式錯誤)")
        tail -5 "$log_file" | sed 's/^/  /'
        return
    fi

    log_info "Step S-2: 下載源碼並分析..."
    local source_json
    source_json=$(bash "$SCRIPT_DIR/download-and-checksum.sh" "$src_url" "$kind" "$sname" "$commit" 2>"$log_file.download") || {
        log_err "源碼下載/分析失敗"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (下載源碼失敗)")
        cat "$log_file.download" | sed 's/^/  /'
        return
    }

    local dl_kind dl_url dl_digest dl_name dl_commit
    dl_kind=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['kind'])")
    dl_url=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
    dl_digest=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('digest',''))")
    dl_name=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))")
    dl_commit=$(echo "$source_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('commit',''))")
    log_ok "源碼分析完成: kind=$dl_kind, name=$dl_name"

    log_info "Step S-3: 更新 linglong.yaml..."
    local update_cmd="python3 \"$SCRIPT_DIR/update-linglong-yaml.py\" \
        --path=\"$project_dir\" \
        --kind=\"$dl_kind\" \
        --url=\"$dl_url\" \
        --digest=\"$dl_digest\" \
        --name=\"$dl_name\""
    if [[ -n "$dl_commit" ]]; then
        update_cmd="$update_cmd --commit=\"$dl_commit\""
    fi
    if eval "$update_cmd" >> "$log_file" 2>&1; then
        log_ok "linglong.yaml 更新完成"
    else
        log_err "linglong.yaml 更新失敗"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (YAML 更新失敗)")
        tail -5 "$log_file" | sed 's/^/  /'
        return
    fi

    log_info "Step S-4: 輸出驗證 linglong.yaml..."
    if python3 "$SCRIPT_DIR/validate-linglong-yaml.py" "$project_dir/linglong.yaml" --allow-sources >> "$log_file" 2>&1; then
        log_ok "輸出驗證通過（含 sources 段）"
    else
        log_err "輸出驗證失敗"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗 (輸出 linglong.yaml 驗證失敗)")
        tail -5 "$log_file" | sed 's/^/  /'
        return
    fi

    local build_phase_ok=false
    local build_attempt=1
    while [[ $build_attempt -le $MAX_BUILD_ATTEMPTS ]]; do
        log_info "Step S-5: ll-builder build 開始（第 ${build_attempt}/${MAX_BUILD_ATTEMPTS} 次）..."
        if (cd "$project_dir" && timeout "$BUILD_TIMEOUT_SEC" ll-builder build --cache-dir "$task_build_tmp_dir" >> "$log_file" 2>&1); then
            log_ok "ll-builder build 成功"
        else
            local build_exit=$?
            if [[ $build_exit -eq 124 ]]; then
                log_err "ll-builder build 超時（${BUILD_TIMEOUT_SEC}s）"
            else
                log_err "ll-builder build 失敗"
            fi
            tail -10 "$log_file" | sed 's/^/  /'
            if [[ $build_attempt -lt $MAX_BUILD_ATTEMPTS ]]; then
                log_warn "構建失敗，${RETRY_INTERVAL} 秒後重試..."
                sleep "$RETRY_INTERVAL"
                build_attempt=$((build_attempt + 1))
                continue
            fi
            build_attempt=$((build_attempt + 1))
            break
        fi

        log_info "Step S-6: ll-builder export 開始（第 ${build_attempt}/${MAX_BUILD_ATTEMPTS} 次）..."
        if (cd "$project_dir" && timeout "$BUILD_TIMEOUT_SEC" ll-builder export --layer --no-develop -z zstd >> "$log_file" 2>&1); then
            log_ok "ll-builder export 成功"
            build_phase_ok=true
            break
        else
            local export_exit=$?
            if [[ $export_exit -eq 124 ]]; then
                log_err "ll-builder export 超時（${BUILD_TIMEOUT_SEC}s）"
            else
                log_err "ll-builder export 失敗"
            fi
            tail -10 "$log_file" | sed 's/^/  /'
            if [[ $build_attempt -lt $MAX_BUILD_ATTEMPTS ]]; then
                log_warn "導出失敗，${RETRY_INTERVAL} 秒後重試（從 build 開始）..."
                sleep "$RETRY_INTERVAL"
                build_attempt=$((build_attempt + 1))
                continue
            fi
            build_attempt=$((build_attempt + 1))
            break
        fi
    done

    if ! $build_phase_ok; then
        log_err "構建階段失敗，已重試 ${build_attempt} 次"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        RESULTS+=("$pkg_name: 失敗（構建階段）")
        tail -10 "$log_file" | sed 's/^/  /'
        local end_time
        end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        log_err "$pkg_name 打包失敗（耗時 ${elapsed}s）"
        return
    fi

    local layer_file
    layer_file=$(find "$project_dir" -maxdepth 1 -name "*.layer" -type f 2>/dev/null | head -1)
    if [[ -n "$layer_file" ]]; then
        mkdir -p "$OUTPUT_DIR"
        mv "$layer_file" "$OUTPUT_DIR/"
        log_ok "產物移動到: $OUTPUT_DIR/$(basename "$layer_file")"
    else
        log_warn "未找到 .layer 產物文件"
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_ok "$pkg_name 打包成功 (耗時 ${elapsed}s)"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    RESULTS+=("$pkg_name: 成功 (${elapsed}s)")
}

log_info "共 $TASK_COUNT 個 source 打包任務"
echo ""

for ((i = 0; i < TASK_COUNT; i++)); do
    run_source_task "$i"
done

print_results_summary "$TASK_COUNT" "$SUCCESS_COUNT" "$FAIL_COUNT" "${RESULTS[@]}"
