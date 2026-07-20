#!/usr/bin/env bash
# download-and-checksum.sh — 下载源码、计算 sha256、解压分析目录结构
# 输出 JSON: {kind, url, digest, name, extracted_dir, commit}

set -euo pipefail

URL="${1:-}"
KIND="${2:-auto}"
NAME="${3:-}"
COMMIT="${4:-}"

if [[ -z "$URL" ]]; then
  echo '{"error":"URL is required"}' >&2
  exit 1
fi

WORKDIR=$(mktemp -d /tmp/linyaps-update-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# 自动推断 kind
if [[ "$KIND" == "auto" ]]; then
  case "$URL" in
    *.tar.gz|*.tgz)                KIND="archive" ;;
    *.tar.xz|*.txz)                KIND="archive" ;;
    *.tar.bz2|*.tbz2)              KIND="archive" ;;
    *.zip)                         KIND="archive" ;;
    *.tar)                         KIND="archive" ;;
    *.dsc)                         KIND="dsc" ;;
    *.git)                         KIND="git" ;;
    *github.com*/*.git)            KIND="git" ;;
    *gitlab.com*/*.git)            KIND="git" ;;
    *gitcode.*/*.git)              KIND="git" ;;
    *gitlink.*/*.git)              KIND="git" ;;
    *gitee.com*/*.git)             KIND="git" ;;
    *.patch|*.diff)                KIND="file" ;;
    *.deb)                         KIND="file" ;;
    *)                             KIND="file" ;;
  esac
fi

# 生成默认 name
if [[ -z "$NAME" ]]; then
  case "$KIND" in
    archive) NAME="src" ;;
    git)     NAME="$(basename "$URL" .git)" ;;
    dsc)     NAME="$(basename "$URL" .dsc)" ;;
    file)    NAME="$(basename "$URL")" ;;
  esac
fi

FILENAME=$(basename "$URL")
EXTRACTED_DIR=""

case "$KIND" in
  archive)
    # 下载
    curl -fsSL "$URL" -o "$WORKDIR/$FILENAME"
    DIGEST=$(sha256sum "$WORKDIR/$FILENAME" | cut -d' ' -f1)
    # 解压并获取顶层目录
    case "$FILENAME" in
      *.tar.gz|*.tgz)            tar -xzf "$WORKDIR/$FILENAME" -C "$WORKDIR" ;;
      *.tar.xz|*.txz)            tar -xJf "$WORKDIR/$FILENAME" -C "$WORKDIR" ;;
      *.tar.bz2|*.tbz2)          tar -xjf "$WORKDIR/$FILENAME" -C "$WORKDIR" ;;
      *.zip)                     unzip -q "$WORKDIR/$FILENAME" -d "$WORKDIR" ;;
      *.tar)                     tar -xf "$WORKDIR/$FILENAME" -C "$WORKDIR" ;;
    esac
    # 查找顶层目录（排除隐藏文件）
    EXTRACTED_DIR=$(cd "$WORKDIR" && ls -d */ 2>/dev/null | head -1 | sed 's|/$||')
    if [[ -z "$EXTRACTED_DIR" ]]; then
      EXTRACTED_DIR="$NAME"
    fi
    ;;
  git)
    if [[ -z "$COMMIT" ]]; then
      git clone --depth 1 "$URL" "$WORKDIR/repo"
    else
      git clone "$URL" "$WORKDIR/repo"
      (cd "$WORKDIR/repo" && git checkout "$COMMIT")
    fi
    DIGEST=$(cd "$WORKDIR/repo" && git rev-parse HEAD)
    rm -rf "$WORKDIR/repo/.git"
    EXTRACTED_DIR="$NAME"
    ;;
  file)
    curl -fsSL "$URL" -o "$WORKDIR/$FILENAME"
    DIGEST=$(sha256sum "$WORKDIR/$FILENAME" | cut -d' ' -f1)
    ;;
  dsc)
    curl -fsSL "$URL" -o "$WORKDIR/$FILENAME"
    DIGEST=$(sha256sum "$WORKDIR/$FILENAME" | cut -d' ' -f1)
    EXTRACTED_DIR="$NAME"
    ;;
esac

# 输出 JSON
cat <<EOF
{
  "kind": "$KIND",
  "url": "$URL",
  "digest": "$DIGEST",
  "name": "$NAME",
  "extracted_dir": "$EXTRACTED_DIR",
  "commit": "$COMMIT"
}
EOF