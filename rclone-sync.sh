#!/usr/bin/env bash
set -euo pipefail

# ---- Required env vars (fail fast if missing)
: "${JAVA_PROPERTY_LOG_PATH:?Set JAVA_PROPERTY_LOG_PATH (e.g., /opt/glassfish/domains/mydomain/logs)}"
: "${S3_BUCKET:?Set S3_BUCKET (bucket name only, no s3://)}"
: "${DOMAIN_NAME:?Set DOMAIN_NAME}"
: "${KMS_KEY_ID:?Set KMS_KEY_ID (AWS KMS key id or ARN)}"

RCLONE_CONF_DIR="/etc/rclone"
RCLONE_CONF_FILE="${RCLONE_CONF_DIR}/rclone.conf"
RCLONE_FILTER_FILE="${RCLONE_CONF_DIR}/filters.txt"
LOGROTATE_SNIPPET="/etc/logrotate.d/java_logs"

# Hourly loop (3600 seconds)
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-3600}"

# Retention for rotated logs inside the container (ephemeral anyway, but keeps things tidy)
ROTATE_COUNT="${ROTATE_COUNT:-24}"   # keep ~24 hourly rotations
MAXAGE_DAYS="${MAXAGE_DAYS:-1}"      # keep ~1 day

# ---- Create rclone config
mkdir -p "${RCLONE_CONF_DIR}"
cat > "${RCLONE_CONF_FILE}" <<'EOF'
[s3]
type = s3
provider = AWS
env_auth = true
region = us-east-1
acl = private
server_side_encryption = aws:kms
storage_class = STANDARD
EOF

# ---- Create rclone filter file
# Rules are evaluated top-to-bottom; first match wins.
# - Exclude actively-written .container log files (e.g. server.log.container.1)
# + Include rotated numbered logs (e.g. server.log.1, server.log.2)
#   NOTE: nocompress is set in logrotate, so .gz files are never produced;
#         the .gz line is intentionally omitted to avoid dead/misleading rules.
# - Exclude everything else (active .log files still being written to,
#   and any other files we don't care about)
cat > "${RCLONE_FILTER_FILE}" <<'EOF'
- *.container.[1-9]*
+ *.log.[1-9]*
- *
EOF

# ---- Create logrotate config (hourly)
mkdir -p /etc/logrotate.d
mkdir -p /var/lib/logrotate
cat > "${LOGROTATE_SNIPPET}" <<EOF
${JAVA_PROPERTY_LOG_PATH}/*.log
/opt/glassfish/jbi/checksum.log
/opt/glassfish/domains/${DOMAIN_NAME}/config/derby.log
{
  hourly
  rotate ${ROTATE_COUNT}
  maxage ${MAXAGE_DAYS}
  missingok
  notifempty
  copytruncate
  nocompress
}
EOF

echo "---- rclone.conf ----"
cat "${RCLONE_CONF_FILE}"
echo "---- rclone filters ----"
cat "${RCLONE_FILTER_FILE}"
echo "---- logrotate snippet ----"
cat "${LOGROTATE_SNIPPET}"

run_rotate() {
  echo "Running logrotate at $(date)"
  # Store state so hourly rotation works correctly inside the container
  /usr/sbin/logrotate -v -s /var/lib/logrotate/status /etc/logrotate.conf
}

run_sync_rotated_only() {
  echo "Starting rclone sync (rotated logs only) at $(date)"
  rclone sync \
    --config "${RCLONE_CONF_FILE}" \
    --s3-server-side-encryption "aws:kms" \
    --s3-sse-kms-key-id "${KMS_KEY_ID}" \
    --s3-no-check-bucket \
    --create-empty-src-dirs \
    --filter-from "${RCLONE_FILTER_FILE}" \
    "${JAVA_PROPERTY_LOG_PATH}" \
    "s3:${S3_BUCKET}/"
}

# ---- Start rotate & sync loop (background)
(
  while true; do
    # Rotate first so logs become stable files, then sync only rotated files.
    # If logrotate fails, skip the sync for this cycle to avoid uploading
    # partial or inconsistent state.
    if ! run_rotate; then
      echo "logrotate failed at $(date), skipping sync this cycle."
    else
      if run_sync_rotated_only; then
        echo "rclone sync succeeded at $(date)."
      else
        RC=$?
        echo "rclone sync failed with exit code ${RC} at $(date)."
      fi
    fi
    sleep "${SYNC_INTERVAL_SECONDS}"
  done
) &

# ---- Start GlassFish domain (foreground)
echo "Starting GlassFish domain '${DOMAIN_NAME}'..."
exec /opt/glassfish/bin/asadmin start-domain --verbose --user admin "${DOMAIN_NAME}"
