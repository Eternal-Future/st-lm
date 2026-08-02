#!/bin/sh

set -eu

cd /home/node/app

echo "[startup] Starting restore process..."
/usr/local/bin/restore.sh

# 第一次启动、且 S3 中没有备份时，创建并保护 default-user
if [ ! -d "./data/_storage" ] ||
   ! find "./data/_storage" -type f -print -quit 2>/dev/null |
   grep -q .; then

    echo "[startup] No initialized user database found."

    if [ -z "${ST_ADMIN_PASSWORD:-}" ]; then
        echo "[startup] ERROR: ST_ADMIN_PASSWORD is required."
        exit 1
    fi

    echo "[startup] Creating default-user administrator..."
    node recover.js default-user "${ST_ADMIN_PASSWORD}"

    echo "[startup] default-user password configured."
else
    echo "[startup] Existing user database found."
fi

echo "[startup] Starting backup scheduler..."
crond -b -l 8

echo "[startup] Starting SillyTavern..."
exec ./docker-entrypoint.sh "$@"
