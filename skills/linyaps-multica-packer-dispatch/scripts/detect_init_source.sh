#!/usr/bin/env bash
# linyaps-multica-packer-dispatch: detect_init_source.sh
#
# 检测当前打包任务是否由 linyaps-init（binary 初始化）或
# linyaps-src-init（源码初始化）节点触发。
#
# 输出（JSON，写入选定路径或 stdout）：
#   { "IS_INIT_ASSIGNED": false, "SRC_INIT_ASSIGNED": false }
#
# 使用方式：
#   bash detect_init_source.sh [--workspace=<slug>] [--output=<path>]

set -euo pipefail

WORKSPACE=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace=*) WORKSPACE="${1#*=}" ;;
    --output=*)    OUTPUT_FILE="${1#*=}" ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
  shift
done

IS_INIT_ASSIGNED=false
SRC_INIT_ASSIGNED=false

# 检测 multica CLI 是否可用
if ! command -v multica &>/dev/null; then
  echo '{"IS_INIT_ASSIGNED":false,"SRC_INIT_ASSIGNED":false}' >&2
  echo '{"IS_INIT_ASSIGNED":false,"SRC_INIT_ASSIGNED":false}'
  exit 0
fi

# 切换到指定 workspace
if [[ -n "$WORKSPACE" ]]; then
  multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
fi

# 查询当前 issue ID
ISSUE_ID=$(multica issue list --limit 10 2>/dev/null | grep -oP 'issue-\d+' | head -1)

if [[ -z "$ISSUE_ID" ]]; then
  echo '{"IS_INIT_ASSIGNED":false,"SRC_INIT_ASSIGNED":false}'
  exit 0
fi

# 获取评论内容
COMMENTS=$(multica issue comments "$ISSUE_ID" 2>/dev/null || echo "")

if echo "$COMMENTS" | grep -q "linyaps-init"; then
  IS_INIT_ASSIGNED=true
elif echo "$COMMENTS" | grep -q "linyaps-src-init"; then
  SRC_INIT_ASSIGNED=true
fi

RESULT=$(cat <<JSON
{"IS_INIT_ASSIGNED":${IS_INIT_ASSIGNED},"SRC_INIT_ASSIGNED":${SRC_INIT_ASSIGNED}}
JSON
)

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$RESULT" > "$OUTPUT_FILE"
else
  echo "$RESULT"
fi