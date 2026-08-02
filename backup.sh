#!/bin/sh

set -eu
set -o pipefail

APP_DIR="/home/node/app"
PREFIX="${S3_PREFIX:-sillytavern-backups}"
REMOTE="s3:${S3_BUCKET:-}/${PREFIX}"
LOCK_DIR="/tmp/sillytavern-backup.lock"
LIST_FILE="/tmp/sillytavern-backup-list.txt"

if [ -z "${S3_BUCKET:-}" ]; then
    echo "[backup] S3_BUCKET not configured; skipping backup."
    exit 0
fi

# 没有初始化用户数据库时不要上传空备份
if [ ! -d "${APP_DIR}/data/_storage" ] ||
   ! find "${APP_DIR}/data/_storage" -type f -print -quit 2>/dev/null |
   grep -q .; then
    echo "[backup] User database not initialized; skipping backup."
    exit 0
fi

# 防止两个备份任务同时运行
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "[backup] Another backup is already running."
    exit 0
fi

cleanup() {
    rm -rf "${LOCK_DIR}"
    rm -f "${LIST_FILE}"
}

trap cleanup EXIT INT TERM

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
BACKUP_NAME="sillytavern-${TIMESTAMP}.tar.gz"

echo "[backup] Uploading ${BACKUP_NAME}..."

# 直接流式压缩上传，不在 1GB 临时磁盘上产生第二份完整文件
tar -C "${APP_DIR}" -cf - data \
    | gzip -1 \
    | rclone \
        --buffer-size 1M \
        --s3-upload-concurrency 1 \
        --s3-chunk-size 5M \
        --retries 3 \
        rcat "${REMOTE}/${BACKUP_NAME}"

echo "[backup] Upload completed."

rclone lsf "${REMOTE}" \
    --files-only \
    --include "sillytavern-*.tar.gz" \
    > "${LIST_FILE}"

# 文件名包含 UTC 时间，按名称倒序即可得到新旧顺序
LC_ALL=C sort -r "${LIST_FILE}" \
    | awk 'NR > 7' \
    | while IFS= read -r OLD_BACKUP; do
        [ -n "${OLD_BACKUP}" ] || continue

        echo "[backup] Deleting old backup: ${OLD_BACKUP}"
        rclone deletefile "${REMOTE}/${OLD_BACKUP}"
    done

echo "[backup] Retention complete; newest 7 backups retained."
