#!/usr/bin/env bash
# linyaps-multica-packer-dispatch: dispatch.sh
#
# 统一指派入口脚本，三种 action：
#   detect_init_source       — 检测初始化来源
#   dispatch_project_not_found — 项目未找到时发起指派
#   update_issue_status       — 更新 issue 状态
#
# 使用方式：
#   bash dispatch.sh detect_init_source [--workspace=<slug>] [--output=<path>]
#   bash dispatch.sh dispatch_project_not_found --pkgName=<name> --src_url=<url> --arch=<arch> --type=<binary|source> [--workspace=<slug>] [--data-dir=<path>] [--config=<path>]
#   bash dispatch.sh update_issue_status --success=<n> --fail=<n> --pending=<n> --src-pending=<n> [--workspace=<slug>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_ROOT/../../.." && pwd)"

ACTION="${1:-}"
shift || true

# ---- 参数解析 ----
WORKSPACE=""
OUTPUT_FILE=""
PKG_NAME=""
SRC_URL=""
ARCH=""
TYPE=""
DATA_DIR=""
CONFIG_FILE="${REPO_ROOT}/for-multica/agent-config.json"
SUCCESS_COUNT=0
FAIL_COUNT=0
PENDING_COUNT=0
SRC_PENDING_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace=*)  WORKSPACE="${1#*=}" ;;
    --output=*)     OUTPUT_FILE="${1#*=}" ;;
    --pkgName=*)    PKG_NAME="${1#*=}" ;;
    --src_url=*)    SRC_URL="${1#*=}" ;;
    --arch=*)       ARCH="${1#*=}" ;;
    --type=*)       TYPE="${1#*=}" ;;
    --data-dir=*)   DATA_DIR="${1#*=}" ;;
    --config=*)     CONFIG_FILE="${1#*=}" ;;
    --success=*)    SUCCESS_COUNT="${1#*=}" ;;
    --fail=*)       FAIL_COUNT="${1#*=}" ;;
    --pending=*)    PENDING_COUNT="${1#*=}" ;;
    --src-pending=*) SRC_PENDING_COUNT="${1#*=}" ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
  shift
done

output_json() {
  local json="$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$json" > "$OUTPUT_FILE"
  else
    echo "$json"
  fi
}

# ---- detect_init_source ----
if [[ "$ACTION" == "detect_init_source" ]]; then
  exec bash "$SCRIPT_DIR/detect_init_source.sh" \
    ${WORKSPACE:+--workspace="$WORKSPACE"} \
    ${OUTPUT_FILE:+--output="$OUTPUT_FILE"}

# ---- dispatch_project_not_found ----
elif [[ "$ACTION" == "dispatch_project_not_found" ]]; then
  if [[ -z "$PKG_NAME" || -z "$SRC_URL" || -z "$ARCH" || -z "$TYPE" ]]; then
    echo '{"error":"缺少必填参数: --pkgName, --src_url, --arch, --type"}' >&2
    exit 1
  fi
  if [[ "$TYPE" != "binary" && "$TYPE" != "source" ]]; then
    echo '{"error":"type 必须是 binary 或 source"}' >&2
    exit 1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{"error":"agent-config.json 不存在: '"$CONFIG_FILE"'"}' >&2
    exit 1
  fi

  # 读取配置，筛选目标 agent
  if [[ "$TYPE" == "binary" ]]; then
    TARGET_CAPABILITY="project_init"
  else
    TARGET_CAPABILITY="src_project_init"
  fi

  TARGET_AGENT_ID=$(python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
agents = cfg.get('assignment', {}).get('agents', [])
cap = '$TARGET_CAPABILITY'
for a in agents:
    if cap in a.get('capabilities', []):
        print(a['id'])
        sys.exit(0)
" 2>/dev/null || true)

  if [[ -z "$TARGET_AGENT_ID" ]]; then
    echo '{"error":"未找到 capabilities 包含 '"$TARGET_CAPABILITY"' 的 agent"}' >&2
    # 不阻断，标记为未指派
    output_json "{\"assigned\":false,\"target_agent\":\"\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
    exit 0
  fi

  # 状态检查（热备方案）
  AGENT_STATUS="unknown"
  if command -v multica &>/dev/null; then
    WS_ARG=""
    if [[ -n "$WORKSPACE" ]]; then
      WS_ARG="-w $WORKSPACE"
    fi
    STATUS_RESULT=$(bash "$SCRIPT_DIR/check-agent-status.sh" \
      $WS_ARG -n "$TARGET_AGENT_ID" -o json 2>/dev/null || true)
    if [[ -n "$STATUS_RESULT" ]]; then
      AGENT_STATUS=$(echo "$STATUS_RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('agent', {}).get('status', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null) || AGENT_STATUS="unknown"
    fi
    if [[ "$AGENT_STATUS" == "idle" ]]; then
      echo "[INFO] 目标智能体 ${TARGET_AGENT_ID} 空闲，可立即指派" >&2
    elif [[ "$AGENT_STATUS" == "busy" || "$AGENT_STATUS" == "running" ]]; then
      echo "[WARN] 目标智能体 ${TARGET_AGENT_ID} 当前繁忙，仍发起指派（由平台排队处理）" >&2
    else
      echo "[WARN] 无法查询目标智能体 ${TARGET_AGENT_ID} 状态（${AGENT_STATUS}），直接发起指派" >&2
    fi
  else
    echo "[WARN] multica CLI 不可用，跳过状态检查" >&2
  fi

  # 指派执行
  ASSIGNED=false
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    ISSUE_ID=$(multica issue list --limit 10 2>/dev/null | grep -oP 'issue-\d+' | head -1)
    if [[ -n "$ISSUE_ID" ]]; then
      TYPE_TAG=""
      [[ "$TYPE" == "source" ]] && TYPE_TAG="，類型：source"
      multica issue comment add "$ISSUE_ID" \
        --content "@${TARGET_AGENT_ID} 請為 ${PKG_NAME} 進行項目初始化適配工作（${ARCH}）。下載地址：${SRC_URL}${TYPE_TAG}" \
        2>/dev/null && ASSIGNED=true || echo "[WARN] multica comment 发送失败" >&2
    else
      echo "[WARN] 无法查询 ISSUE_ID，跳过指派" >&2
    fi
  else
    echo "[WARN] multica CLI 不可用，跳过指派" >&2
  fi

  # 记录指派日志
  if [[ -n "$DATA_DIR" ]]; then
    mkdir -p "$DATA_DIR"
    if [[ "$TYPE" == "binary" ]]; then
      echo "assigned_init, ${PKG_NAME}, ${TARGET_AGENT_ID}, ${ARCH}, $(date +'%Y-%m-%d %H:%M:%S')" >> "${DATA_DIR}/assignment.log"
    else
      echo "assigned_src_init, ${PKG_NAME}, ${TARGET_AGENT_ID}, ${ARCH}, source, $(date +'%Y-%m-%d %H:%M:%S')" >> "${DATA_DIR}/assignment.log"
    fi
  fi

  output_json "$(cat <<JSON
{"assigned":${ASSIGNED},"target_agent":"${TARGET_AGENT_ID}","timestamp":"$(date +'%Y-%m-%d %H:%M:%S')","agent_status":"${AGENT_STATUS}"}
JSON
)"

# ---- update_issue_status ----
elif [[ "$ACTION" == "update_issue_status" ]]; then
  # 计算 issue 状态
  if [[ "$FAIL_COUNT" -eq 0 && "$PENDING_COUNT" -eq 0 && "$SRC_PENDING_COUNT" -eq 0 ]]; then
    ISSUE_STATUS="审查完成"
  elif [[ "$SUCCESS_COUNT" -eq 0 && "$FAIL_COUNT" -gt 0 && "$PENDING_COUNT" -eq 0 && "$SRC_PENDING_COUNT" -eq 0 ]]; then
    ISSUE_STATUS="阻塞"
  elif [[ "$PENDING_COUNT" -gt 0 || "$SRC_PENDING_COUNT" -gt 0 ]]; then
    ISSUE_STATUS="进行中"
  else
    ISSUE_STATUS="部分完成"
  fi

  COMMENT_ID=""
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    ISSUE_ID=$(multica issue list --limit 10 2>/dev/null | grep -oP 'issue-\d+' | head -1)
    if [[ -n "$ISSUE_ID" ]]; then
      COMMENT_ID=$(multica issue comment add "$ISSUE_ID" \
        --content "結果：成功 ${SUCCESS_COUNT} / 失敗 ${FAIL_COUNT} / 待初始化 ${PENDING_COUNT} / 待源码初始化 ${SRC_PENDING_COUNT}" \
        2>/dev/null | grep -oP 'comment-\d+' | head -1) || COMMENT_ID=""
    fi
  fi

  output_json "$(cat <<JSON
{"issue_status":"${ISSUE_STATUS}","comment_id":"${COMMENT_ID:-""}"}
JSON
)"

else
  echo "未知 action: ${ACTION}" >&2
  echo "可用 action: detect_init_source, dispatch_project_not_found, update_issue_status" >&2
  exit 1
fi