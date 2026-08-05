#!/bin/sh

set -eu
set -o pipefail

APP_DIR="/home/node/app"
DATA_DIR="${APP_DIR}/data"
EXTENSIONS_DIR="${APP_DIR}/public/scripts/extensions/third-party"
PLUGINS_DIR="${APP_DIR}/plugins"

PREFIX="${S3_PREFIX:-sillytavern-backups}"
REMOTE="s3:${S3_BUCKET:-}/${PREFIX}"
RETENTION_COUNT="${BACKUP_RETENTION:-7}"

LOCK_DIR="/tmp/sillytavern-maintenance.lock"
LOCK_HELD=0
LIST_FILE="/tmp/sillytavern-backup-list.$$.txt"
DELETE_FILE="/tmp/sillytavern-backup-delete-list.$$.txt"

has_user_database() {
    directory="$1"

    [ -d "${directory}/_storage" ] &&
        [ ! -L "${directory}/_storage" ] &&
        [ -n "$(find "${directory}/_storage" -type f -print -quit 2>/dev/null)" ]
}

cleanup() {
    if [ "${LOCK_HELD}" -eq 1 ]; then
        rm -rf "${LOCK_DIR}"
    fi

    rm -f "${LIST_FILE}" "${DELETE_FILE}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -z "${S3_BUCKET:-}" ]; then
    echo "[backup] S3_BUCKET not configured; skipping backup."
    exit 0
fi

case "${RETENTION_COUNT}" in
    ''|*[!0-9]*|0)
        echo "[backup] ERROR: BACKUP_RETENTION must be a positive integer." >&2
        exit 1
        ;;
esac

# 没有初始化用户数据库时，不上传空备份或仅含程序目录的备份。
if ! has_user_database "${DATA_DIR}"; then
    echo "[backup] User database not initialized; skipping backup."
    exit 0
fi

# 备份与恢复共用同一个锁，避免同时改动持久化目录。
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "[backup] Another backup or restore task is already running."
    exit 0
fi
LOCK_HELD=1

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
BACKUP_NAME="sillytavern-${TIMESTAMP}.tar.gz"

# data 始终备份；另外两个目录存在时一并备份。
set -- data

if [ -d "${EXTENSIONS_DIR}" ]; then
    set -- "$@" public/scripts/extensions/third-party
fi

if [ -d "${PLUGINS_DIR}" ]; then
    set -- "$@" plugins
fi

echo "[backup] Uploading ${BACKUP_NAME}..."

# 流式压缩上传，不在临时磁盘生成完整压缩包。
# 排除恢复脚本自身的工作目录和中断标记。
tar \
    --exclude='data/.restore-in-progress' \
    --exclude='data/.restore-work' \
    -C "${APP_DIR}" \
    -cf - \
    "$@" \
    | gzip -1 \
    | rclone \
        --buffer-size 1M \
        --s3-upload-concurrency 1 \
        --s3-chunk-size 5M \
        --retries 3 \
        --low-level-retries 5 \
        rcat "${REMOTE}/${BACKUP_NAME}"

echo "[backup] Upload completed."

if ! rclone \
    --retries 3 \
    --low-level-retries 5 \
    lsf "${REMOTE}" \
    --files-only \
    --include 'sillytavern-*.tar.gz' \
    > "${LIST_FILE}"; then

    echo "[backup] ERROR: Upload succeeded, but retention listing failed." >&2
    exit 1
fi

# 文件名包含 UTC 时间，按名称倒序就是从新到旧。
LC_ALL=C sort -r "${LIST_FILE}" \
    | awk -v keep="${RETENTION_COUNT}" 'NR > keep' \
    > "${DELETE_FILE}"

while IFS= read -r OLD_BACKUP; do
    [ -n "${OLD_BACKUP}" ] || continue

    echo "[backup] Deleting old backup: ${OLD_BACKUP}"
    rclone \
        --retries 3 \
        --low-level-retries 5 \
        deletefile "${REMOTE}/${OLD_BACKUP}"
done < "${DELETE_FILE}"

echo "[backup] Retention complete; newest ${RETENTION_COUNT} backups retained."
