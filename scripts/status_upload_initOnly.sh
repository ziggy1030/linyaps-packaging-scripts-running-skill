#!/bin/bash
# status_upload.sh — 打包產物上傳與狀態回報
#
# 用途：每個任務打包完成後，將構建產物上傳至 S3 並向 cooperation.uniontech.com webhook 回報狀態。
# 無論打包成功或失敗都必須調用，僅 filepath 和 pakStatus 不同。
#
# 用法：bash ./scripts/status_upload.sh <linyapsPkgName> <linyapsPkgArch> <pakStatus> <filepath> <upstreamVer> <linyapsPkgVer> <linyapsPkgUrl>
#
# 參數說明：
#   $1  linyapsPkgName  — 包名（對應 task.pkgName）
#   $2  linyapsPkgArch  — 架構（對應 task.arch，如 x86_64、arm64）
#   $3  pakStatus       — 打包狀態：non-verified（成功）或 failed（失敗）
#   $4  filepath         — 構建產物文件完整路徑（成功時）；"null" 表示跳過上傳（失敗時）
#   $5  upstreamVer      — 上游版本號（對應 task.orig_version）
#   $6  linyapsPkgVer    — linyaps 包版本（一般同 upstreamVer）
#   $7  linyapsPkgUrl    — 成功時為 S3 產物 URL；失敗時固定為 "null"（對應 task.src_url）
#
# 範例：
#   # 打包成功
#   bash ./scripts/status_upload.sh com.opera.browser x86_64 non-verified \
#     /data/output/2026-06-17/com.opera.browser_130.0.5847.92_x86_64.layer \
#     130.0.5847.92 130.0.5847.92 https://download3.operacdn.com/.../opera-stable_130.0.5847.92_amd64.deb
#
#   # 打包失敗（不上傳產物，linyapsPkgUrl 固定為 null）
#   bash ./scripts/status_upload.sh com.opera.browser x86_64 failed null \
#     130.0.5847.92 130.0.5847.92 null
#
# 前置依賴：rclone（用於 S3 上傳）、curl（用於 webhook 通知）
# 原始腳本來源：example/update-app-version-SKILL/update.sh

set -xe
echo "status_upload: $1 - $2 - $3 - $4 - $5 - $6 - $7"

linyapsPkgName=$1
linyapsPkgArch=$2
pakStatus=$3
filepath=$4
upstreamVer=$5
linyapsPkgVer=$6
linyapsPkgUrl=$7
s3path="$(basename "$filepath")"
dateTag="$(date +"%Y-%m-%d")"

if [ "$pakStatus" = "failed" ]; then
	echo "skip upload (status: failed)"
	linyapsPkgUrl="null"
elif [ "$filepath" = "null" ]; then
	echo "skip upload (filepath is null, status: $pakStatus)"
	linyapsPkgUrl="null"
else
	echo "   uploading file to S3"
	rclone copyto -P "$filepath" "cicd2:/linyaps/packaging-CI-output/${dateTag}/$s3path"
	echo "   file uploaded"
	linyapsPkgUrl="https://rustfsadmin.cicd2.getdeepin.org/linyaps/packaging-CI-output/${dateTag}/$s3path"
	echo "   file url: $linyapsPkgUrl"
fi

echo "   reporting status: $pakStatus"
curl -q "https://cooperation.uniontech.com/api/workflow/hooks/NmEzZDFjMGQxMDM5YjQ1YWRlNGE2OWFh?linyapsPkgName=$linyapsPkgName&linyapsPkgArch=$linyapsPkgArch&pakStatus=$pakStatus&upstreamVer=$upstreamVer&linyapsPkgVer=$linyapsPkgVer&linyapsPkgUrl=$linyapsPkgUrl"


echo "done"
