#!/bin/bash
# verify_upload.sh — 验证S3上传是否成功
#
# 用途：rclone上传后，通过wget下载验证文件是否可访问且有数据传输
# 逻辑：5秒内有下载进度表示上传成功，否则视为失败
#
# 用法：bash ./scripts/verify_upload.sh <file_url> [timeout]
#
# 参数：
#   $1  file_url — 要验证的文件URL
#   $2  timeout — 超时秒数（默认5）
#
# 返回值：
#   0 — 验证通过（有下载进度）
#   1 — 验证失败（超时或无进度）
#
# 示例：
#   bash ./scripts/verify_upload.sh "https://example.com/file.layer"
#   bash ./scripts/verify_upload.sh "https://example.com/file.layer" 10

set -e

file_url="$1"
timeout_sec="${2:-5}"

if [ -z "$file_url" ]; then
    echo "用法: $0 <file_url> [timeout]"
    exit 1
fi

echo "验证上传: $file_url"
echo "超时: ${timeout_sec}s"

# 使用wget下载前1KB，检查是否有数据传输
# -q: 静默模式
# --timeout: 连接超时
# -O -: 输出到stdout
# dd: 只读取前1KB
downloaded=$(timeout "${timeout_sec}" wget -q --timeout="$timeout_sec" --tries=1 -O - "$file_url" 2>/dev/null | dd bs=1024 count=1 2>/dev/null | wc -c)

if [ "$downloaded" -gt 0 ]; then
    echo "✓ 验证通过：下载了 ${downloaded} 字节"
    exit 0
else
    echo "✗ 验证失败：无数据传输"
    exit 1
fi
