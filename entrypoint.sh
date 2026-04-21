#!/bin/sh
set -e

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${KMS_KEY_ID:?KMS_KEY_ID is required}"

SYNC_INTERVAL="${SYNC_INTERVAL:-900}"
LOG_PATH="${LOG_PATH:-/logs}"
S3_PREFIX="${S3_PREFIX:-active}"
S3_DEST="s3://${S3_BUCKET}/${S3_PREFIX}/$(hostname)"

run_sync() {
    echo "[$(date)] Starting s3 sync..."
    aws s3 sync "$LOG_PATH" "$S3_DEST" \
        --sse aws:kms \
        --sse-kms-key-id "$KMS_KEY_ID" \
        --exclude "*" \
        --include "*.container" \
        --exact-timestamps
    echo "[$(date)] Sync complete (exit: $?)"
}

trap 'echo "[$(date)] Caught signal, running final sync..."; run_sync; exit 0' TERM INT

echo "Sidecar starting: syncing ${LOG_PATH} -> ${S3_DEST} every ${SYNC_INTERVAL}s"

while true; do
    run_sync
    sleep "$SYNC_INTERVAL" &
    wait $!
done
