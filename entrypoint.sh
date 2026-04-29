#!/bin/sh
set -eu

S3_SYNC_ENABLED="${S3_SYNC_ENABLED:-true}"
SYNC_INTERVAL="${SYNC_INTERVAL:-900}"
LOG_PATH="${LOG_PATH:-/logs}"
UPLOAD_PATH="${UPLOAD_PATH:-/logs/.to_upload}"
S3_PREFIX="${S3_PREFIX:-active}"
LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.d/middleware_logs}"
LOG_GLOB="${LOG_GLOB:-*.container}"

# S3 vars only required when sync is enabled
if [ "$S3_SYNC_ENABLED" = "true" ]; then
    : "${S3_BUCKET:?S3_BUCKET is required when S3_SYNC_ENABLED=true}"
    : "${KMS_KEY_ID:?KMS_KEY_ID is required when S3_SYNC_ENABLED=true}"
fi

mkdir -p "$LOG_PATH"
mkdir -p "$UPLOAD_PATH"
mkdir -p "$(dirname "$LOGROTATE_CONF")"

echo "[$(date)] Creating logrotate config at ${LOGROTATE_CONF}"

cat > "$LOGROTATE_CONF" <<EOF
${LOG_PATH}/${LOG_GLOB} {
    rotate 8
    missingok
    ifempty
    copytruncate
    nocompress
    dateext
    dateformat -%Y%m%d-%H%M%S
    olddir ${UPLOAD_PATH}
}
EOF

run_logrotate() {
    echo "[$(date)] Starting forced logrotate..."
    /usr/sbin/logrotate -vf "$LOGROTATE_CONF" 2>&1
    LOGROTATE_RC=$?
    if [ "$LOGROTATE_RC" -ne 0 ]; then
        echo "[$(date)] logrotate failed with exit code ${LOGROTATE_RC}."
        return "$LOGROTATE_RC"
    fi
    echo "[$(date)] logrotate completed."
}

run_upload() {
    S3_DEST="s3://${S3_BUCKET}/${S3_PREFIX}/$(date +%Y%m%d)/$(hostname)"

    if ! find "$UPLOAD_PATH" -type f -print -quit | grep -q .; then
        echo "[$(date)] No files found in ${UPLOAD_PATH}. Nothing to upload."
        return 0
    fi

    # Remove zero-byte files — no value uploading empty logs
    find "$UPLOAD_PATH" -type f -empty -delete
    echo "[$(date)] Removed empty staged files."

    if ! find "$UPLOAD_PATH" -type f -print -quit | grep -q .; then
        echo "[$(date)] All staged files were empty. Nothing to upload."
        return 0
    fi

    echo "[$(date)] Files staged for upload:"
    find "$UPLOAD_PATH" -type f -exec ls -lh {} \;

    echo "[$(date)] Uploading staged logs from ${UPLOAD_PATH} to ${S3_DEST}..."
    aws s3 cp "$UPLOAD_PATH" "$S3_DEST" \
        --recursive \
        --sse aws:kms \
        --sse-kms-key-id "$KMS_KEY_ID"
}

cleanup_upload_path() {
    find "$UPLOAD_PATH" -type f -delete
    find "$UPLOAD_PATH" -type d -empty -delete 2>/dev/null || true
    mkdir -p "$UPLOAD_PATH"
    echo "[$(date)] Cleanup completed."
}

run_cycle() {
    if [ "$S3_SYNC_ENABLED" = "true" ]; then
        # Upload staged files from previous cycle first, rotate only on success
        run_upload
        UPLOAD_RC=$?

        if [ "$UPLOAD_RC" -eq 0 ]; then
            echo "[$(date)] S3 upload succeeded. Cleaning up staged files..."
            cleanup_upload_path
            run_logrotate || return $?
        else
            echo "[$(date)] S3 upload failed with exit code ${UPLOAD_RC}. Keeping staged files for retry. Skipping logrotate."
            return "$UPLOAD_RC"
        fi
    else
        # S3 disabled — rotate and immediately clean up staged files
        echo "[$(date)] S3_SYNC_ENABLED=false. Running logrotate only..."
        run_logrotate || return $?
        cleanup_upload_path
    fi
}

trap 'echo "[$(date)] Caught signal, running final cycle..."; run_cycle; exit 0' TERM INT

echo "Sidecar starting."

while true; do
    run_cycle || true
    sleep "$SYNC_INTERVAL" &
    wait $!
done
