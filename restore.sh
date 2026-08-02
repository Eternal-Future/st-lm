#!/bin/sh

set -eu
set -o pipefail

APP_DIR="/home/node/app"
PREFIX="${S3_PREFIX:-sillytavern-backups}"
REMOTE="s3:${S3_BUCKET:-}/${PREFIX}"
LIST_FILE="/tmp/sillytavern-backup-list.txt"

if [ -z "${S3_BUCKET:-}" ]; then
    echo "[restore] S3_BUCKET not configured; skipping restore."
    exit 0
fi

mkdir -p "${APP_DIR}/data"

# 本地已经有用户数据库时，不覆盖现有数据
if [ -d "${APP_DIR}/data/_storage" ] &&
   find "${APP_DIR}/data/_storage" -type f -print -quit 2>/dev/null |
   grep -q .; then
    echo "[restore] Existing user database found; skipping restore."
    exit 0
fi

echo "[restore] Checking ${REMOTE}..."

if ! rclone lsf "${REMOTE}" \
    --files-only \
    --include "sillytavern-*.tar.gz" \
    > "${LIST_FILE}"; then
    echo "[restore] ERROR: Unable to access S3."
    exit 1
fi

LATEST_BACKUP="$(
    LC_ALL=C sort "${LIST_FILE}" |
    tail -n 1
)"

rm -f "${LIST_FILE}"

if [ -z "${LATEST_BACKUP}" ]; then
    echo "[restore] No backup found; starting a new installation."
    exit 0
fi

echo "[restore] Restoring ${LATEST_BACKUP}..."

rclone \
    --buffer-size 1M \
    cat "${REMOTE}/${LATEST_BACKUP}" \
    | gzip -dc \
    | tar -xf - -C "${APP_DIR}"

echo "[restore] Restore completed."
