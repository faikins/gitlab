#!/bin/sh
set -eu

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${KMS_KEY_ID:?KMS_KEY_ID is required}"

SYNC_INTERVAL="${SYNC_INTERVAL:-900}"
LOG_PATH="${LOG_PATH:-/logs}"
UPLOAD_PATH="${UPLOAD_PATH:-/logs/.to_upload}"
S3_PREFIX="${S3_PREFIX:-active}"
LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.d/middleware_logs}"

# Match your middleware log pattern, for example: mw.log.container
LOG_GLOB="${LOG_GLOB:-*.container}"

mkdir -p "$LOG_PATH"
mkdir -p "$UPLOAD_PATH"
mkdir -p "$(dirname "$LOGROTATE_CONF")"

echo "[$(date)] Creating logrotate config at ${LOGROTATE_CONF}"

cat > "$LOGROTATE_CONF" <<EOF
${LOG_PATH}/${LOG_GLOB} {
    rotate 96
    missingok
    ifempty
    copytruncate
    nocompress
    dateext
    dateformat -%Y%m%d-%H%M%S
    olddir ${UPLOAD_PATH}
}
EOF

echo "[$(date)] Logrotate config:"
cat "$LOGROTATE_CONF"

run_rotate_and_upload() {
    # Stable S3 path: active/<date>/<hostname>/ — no per-run timestamp folder
    S3_DEST="s3://${S3_BUCKET}/${S3_PREFIX}/$(date +%Y%m%d)/$(hostname)"

    echo "[$(date)] Starting forced logrotate..."
    /usr/sbin/logrotate -vf "$LOGROTATE_CONF" 2>&1
    LOGROTATE_RC=$?

    if [ "$LOGROTATE_RC" -ne 0 ]; then
        echo "[$(date)] logrotate failed with exit code ${LOGROTATE_RC}. Skipping S3 upload."
        return "$LOGROTATE_RC"
    fi

    echo "[$(date)] logrotate completed. Checking files staged for upload..."

    if ! find "$UPLOAD_PATH" -type f -print -quit | grep -q .; then
        echo "[$(date)] No files found in ${UPLOAD_PATH}. Nothing to upload."
        return 0
    fi

    echo "[$(date)] Files staged for upload:"
    find "$UPLOAD_PATH" -type f -exec ls -lh {} \;

    echo "[$(date)] Uploading staged logs from ${UPLOAD_PATH} to ${S3_DEST}..."

    aws s3 cp "$UPLOAD_PATH" "$S3_DEST" \
        --recursive \
        --sse aws:kms \
        --sse-kms-key-id "$KMS_KEY_ID"

    UPLOAD_RC=$?

    if [ "$UPLOAD_RC" -eq 0 ]; then
        echo "[$(date)] S3 upload succeeded. Cleaning up uploaded staged files..."

        find "$UPLOAD_PATH" -type f -delete
        find "$UPLOAD_PATH" -type d -empty -delete 2>/dev/null || true
        mkdir -p "$UPLOAD_PATH"

        echo "[$(date)] Cleanup completed."
    else
        echo "[$(date)] S3 upload failed with exit code ${UPLOAD_RC}. Keeping staged files for retry."
        return "$UPLOAD_RC"
    fi
}

trap 'echo "[$(date)] Caught signal, running final rotate/upload..."; run_rotate_and_upload; exit 0' TERM INT

echo "Sidecar starting."
echo "LOG_PATH=${LOG_PATH}"
echo "UPLOAD_PATH=${UPLOAD_PATH}"
echo "LOG_GLOB=${LOG_GLOB}"
echo "S3_PREFIX=${S3_PREFIX}"
echo "SYNC_INTERVAL=${SYNC_INTERVAL}"

while true; do
    run_rotate_and_upload || true
    sleep "$SYNC_INTERVAL" &
    wait $!
done
