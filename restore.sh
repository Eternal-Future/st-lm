#!/bin/sh

set -eu
set -o pipefail

APP_DIR="/home/node/app"
DATA_DIR="${APP_DIR}/data"

PREFIX="${S3_PREFIX:-sillytavern-backups}"
REMOTE="s3:${S3_BUCKET:-}/${PREFIX}"

LIST_FILE="/tmp/sillytavern-backup-list.txt"
SORTED_FILE="/tmp/sillytavern-backup-list-sorted.txt"

# 放在持久化 data 卷中，用来识别异常中断
RESTORE_MARKER="${DATA_DIR}/.restore-in-progress"
RESTORE_WORK="${DATA_DIR}/.restore-work"

cleanup_tmp() {
    rm -f "${LIST_FILE}" "${SORTED_FILE}"
}

trap cleanup_tmp EXIT INT TERM

has_user_database() {
    directory="$1"

    [ -d "${directory}/_storage" ] &&
        find "${directory}/_storage" \
            -type f \
            -print \
            -quit 2>/dev/null |
        grep -q .
}

clear_data_directory() {
    find "${DATA_DIR}" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf {} \;
}

if [ -z "${S3_BUCKET:-}" ]; then
    echo "[restore] S3_BUCKET not configured; skipping restore."
    exit 0
fi

mkdir -p "${DATA_DIR}"

# 标记存在说明上一次恢复被强制终止
if [ -e "${RESTORE_MARKER}" ]; then
    echo "[restore] Interrupted restore detected; clearing partial data."
    clear_data_directory
fi

# 本地数据库已经初始化时绝不覆盖
if has_user_database "${DATA_DIR}"; then
    echo "[restore] Existing user database found; skipping restore."
    exit 0
fi

# 避免把云端备份混合进来源不明的本地残留数据
if find "${DATA_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -print \
    -quit 2>/dev/null |
    grep -q .; then

    echo "[restore] ERROR: Data directory is not empty, but no initialized user database was found."
    exit 1
fi

echo "[restore] Checking ${REMOTE}..."

if ! rclone \
    --retries 3 \
    --low-level-retries 5 \
    lsf "${REMOTE}" \
    --files-only \
    --include "sillytavern-*.tar.gz" \
    > "${LIST_FILE}"; then

    echo "[restore] ERROR: Unable to access S3."
    exit 1
fi

# 从最新到最旧排列
LC_ALL=C sort -r "${LIST_FILE}" > "${SORTED_FILE}"

if [ ! -s "${SORTED_FILE}" ]; then
    echo "[restore] No backup found; starting a new installation."
    exit 0
fi

RESTORED=0

while IFS= read -r BACKUP_NAME; do
    [ -n "${BACKUP_NAME}" ] || continue

    echo "[restore] Trying ${BACKUP_NAME}..."

    rm -rf "${RESTORE_WORK}"
    mkdir -p "${RESTORE_WORK}"

    # 在开始流式解压前写入持久标记
    : > "${RESTORE_MARKER}"

    if rclone \
        --buffer-size 1M \
        --retries 3 \
        --low-level-retries 5 \
        cat "${REMOTE}/${BACKUP_NAME}" \
        | gzip -dc \
        | tar -xf - -C "${RESTORE_WORK}"; then

        # 只有发现有效用户数据库才接受这份备份
        if has_user_database "${RESTORE_WORK}/data"; then

            if ! find "${RESTORE_WORK}/data" \
                -mindepth 1 \
                -maxdepth 1 \
                -exec mv -f {} "${DATA_DIR}/" \;
            then
                echo "[restore] ERROR: Failed to move restored data into place."
                exit 1
            fi

            rm -rf "${RESTORE_WORK}"
            rm -f "${RESTORE_MARKER}"

            if has_user_database "${DATA_DIR}"; then
                echo "[restore] Restore completed from ${BACKUP_NAME}."
                RESTORED=1
                break
            fi
        fi
    fi

    echo "[restore] Backup is unusable; trying an older backup."

    # 清除失败备份产生的全部内容，包括恢复标记
    clear_data_directory
done < "${SORTED_FILE}"

if [ "${RESTORED}" -ne 1 ]; then
    echo "[restore] ERROR: No usable backup could be restored."
    exit 1
fi
