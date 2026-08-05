#!/bin/sh

set -eu
set -o pipefail

APP_DIR="/home/node/app"
DATA_DIR="${APP_DIR}/data"
EXTENSIONS_DIR="${APP_DIR}/public/scripts/extensions/third-party"
PLUGINS_DIR="${APP_DIR}/plugins"

PREFIX="${S3_PREFIX:-sillytavern-backups}"
REMOTE="s3:${S3_BUCKET:-}/${PREFIX}"

LOCK_DIR="/tmp/sillytavern-maintenance.lock"
LOCK_HELD=0
LIST_FILE="/tmp/sillytavern-backup-list.$$.txt"
SORTED_FILE="/tmp/sillytavern-backup-list-sorted.$$.txt"

# 工作目录放在持久化 data 卷中，避免占用有限的临时磁盘。
RESTORE_MARKER="${DATA_DIR}/.restore-in-progress"
RESTORE_WORK="${DATA_DIR}/.restore-work"

has_user_database() {
    directory="$1"

    [ -d "${directory}/_storage" ] &&
        [ ! -L "${directory}/_storage" ] &&
        [ -n "$(find "${directory}/_storage" -type f -print -quit 2>/dev/null)" ]
}

directory_has_entries() {
    directory="$1"

    [ -d "${directory}" ] &&
        [ -n "$(find "${directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

clear_directory_contents() {
    directory="$1"

    [ -d "${directory}" ] || return 0

    find "${directory}" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf {} +
}

move_directory_contents() {
    source_directory="$1"
    destination_directory="$2"

    mkdir -p "${destination_directory}"

    find "${source_directory}" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec mv -f {} "${destination_directory}/" \;
}

staged_optional_directory_is_valid() {
    directory="$1"

    if [ -e "${directory}" ] || [ -L "${directory}" ]; then
        [ -d "${directory}" ] && [ ! -L "${directory}" ]
    else
        return 0
    fi
}

cleanup() {
    rm -f "${LIST_FILE}" "${SORTED_FILE}"

    if [ "${LOCK_HELD}" -eq 1 ]; then
        rm -rf "${LOCK_DIR}"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -z "${S3_BUCKET:-}" ]; then
    echo "[restore] S3_BUCKET not configured; skipping restore."
    exit 0
fi

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "[restore] Another backup or restore task is already running."
    exit 0
fi
LOCK_HELD=1

mkdir -p "${DATA_DIR}"

# 标记内容为 staging：只写入了 data 卷中的临时文件。
# 标记内容为 installing：全局扩展或插件目录可能也已被改动。
if [ -e "${RESTORE_MARKER}" ]; then
    RESTORE_STATE="$(cat "${RESTORE_MARKER}" 2>/dev/null || true)"

    echo "[restore] Interrupted restore detected; clearing partial restore state."
    clear_directory_contents "${DATA_DIR}"

    if [ "${RESTORE_STATE}" = "installing" ]; then
        if grep -qx 'extensions' "${RESTORE_MARKER}" 2>/dev/null; then
            clear_directory_contents "${EXTENSIONS_DIR}"
        fi

        if grep -qx 'plugins' "${RESTORE_MARKER}" 2>/dev/null; then
            clear_directory_contents "${PLUGINS_DIR}"
        fi
    fi
fi

# 本地数据库已经初始化时绝不覆盖。
if has_user_database "${DATA_DIR}"; then
    echo "[restore] Existing user database found; skipping restore."
    exit 0
fi

# 避免把云端备份混入来源不明的本地残留数据。
if directory_has_entries "${DATA_DIR}"; then
    echo "[restore] ERROR: Data directory is not empty, but no initialized user database was found." >&2
    exit 1
fi

echo "[restore] Checking ${REMOTE}..."

if ! rclone \
    --retries 3 \
    --low-level-retries 5 \
    lsf "${REMOTE}" \
    --files-only \
    --include 'sillytavern-*.tar.gz' \
    > "${LIST_FILE}"; then

    echo "[restore] ERROR: Unable to access S3." >&2
    exit 1
fi

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

    # staging 表示尚未改动正式的扩展和插件目录。
    printf '%s\n' 'staging' > "${RESTORE_MARKER}"

    EXTRACTED=0
    TARGETS_TOUCHED=0
    EXTENSIONS_TOUCHED=0
    PLUGINS_TOUCHED=0

    if rclone \
        --buffer-size 1M \
        --retries 3 \
        --low-level-retries 5 \
        cat "${REMOTE}/${BACKUP_NAME}" \
        | gzip -dc \
        | tar -xf - -C "${RESTORE_WORK}"; then

        EXTRACTED=1
    fi

    STAGED_DATA="${RESTORE_WORK}/data"
    STAGED_EXTENSIONS="${RESTORE_WORK}/public/scripts/extensions/third-party"
    STAGED_PLUGINS="${RESTORE_WORK}/plugins"

    if [ "${EXTRACTED}" -eq 1 ] \
        && has_user_database "${STAGED_DATA}" \
        && staged_optional_directory_is_valid "${STAGED_EXTENSIONS}" \
        && staged_optional_directory_is_valid "${STAGED_PLUGINS}"; then

        # 从这里开始可能改动正式目录；异常中断时需一并清理。
        {
            printf '%s\n' 'installing'

            if [ -d "${STAGED_EXTENSIONS}" ]; then
                printf '%s\n' 'extensions'
            fi

            if [ -d "${STAGED_PLUGINS}" ]; then
                printf '%s\n' 'plugins'
            fi
        } > "${RESTORE_MARKER}"

        TARGETS_TOUCHED=1
        INSTALL_OK=1

        if [ -d "${STAGED_EXTENSIONS}" ]; then
            EXTENSIONS_TOUCHED=1
            echo "[restore] Restoring global UI extensions..."

            if ! clear_directory_contents "${EXTENSIONS_DIR}" \
                || ! move_directory_contents "${STAGED_EXTENSIONS}" "${EXTENSIONS_DIR}"; then
                INSTALL_OK=0
            fi
        else
            echo "[restore] Global UI extensions are absent in this backup; leaving the current directory unchanged."
        fi

        if [ "${INSTALL_OK}" -eq 1 ] && [ -d "${STAGED_PLUGINS}" ]; then
            PLUGINS_TOUCHED=1
            echo "[restore] Restoring server plugins..."

            if ! clear_directory_contents "${PLUGINS_DIR}" \
                || ! move_directory_contents "${STAGED_PLUGINS}" "${PLUGINS_DIR}"; then
                INSTALL_OK=0
            fi
        elif [ "${INSTALL_OK}" -eq 1 ]; then
            echo "[restore] Server plugins are absent in this backup; leaving the current directory unchanged."
        fi

        if [ "${INSTALL_OK}" -eq 1 ]; then
            echo "[restore] Restoring user data..."

            # 保留当前恢复工作目录和标记，其他归档内容移入正式 data 目录。
            if ! find "${STAGED_DATA}" \
                -mindepth 1 \
                -maxdepth 1 \
                ! -name '.restore-in-progress' \
                ! -name '.restore-work' \
                -exec mv -f {} "${DATA_DIR}/" \;; then
                INSTALL_OK=0
            fi
        fi

        if [ "${INSTALL_OK}" -eq 1 ]; then
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

    # data 一定可能含有解压残留；可选目录只在确实动过时清理。
    clear_directory_contents "${DATA_DIR}"

    if [ "${TARGETS_TOUCHED}" -eq 1 ] && [ "${EXTENSIONS_TOUCHED}" -eq 1 ]; then
        clear_directory_contents "${EXTENSIONS_DIR}"
    fi

    if [ "${TARGETS_TOUCHED}" -eq 1 ] && [ "${PLUGINS_TOUCHED}" -eq 1 ]; then
        clear_directory_contents "${PLUGINS_DIR}"
    fi
done < "${SORTED_FILE}"

if [ "${RESTORED}" -ne 1 ]; then
    echo "[restore] ERROR: No usable backup could be restored." >&2
    exit 1
fi
