# Implementation Prompt: ECS Fargate Log Sync Sidecar

## Objective

Decouple log-to-S3 shipping from the Middleware ECS Fargate container by moving it into a dedicated sidecar container. This eliminates resource contention (memory/CPU) on the critical middleware service that other microservices depend on.

---

## Current State

The middleware container currently runs **everything in a single container**:
1. Glassfish application server (the actual middleware service)
2. rclone sync loop (ships logs to S3 every 5 minutes — resource-intensive)
3. logrotate (truncates logs daily to prevent unbounded growth)

The rclone sync runs as a background subshell in the entrypoint script, competing directly with Glassfish for container memory and CPU.

**Current S3 destination pattern:** `s3://<BUCKET>/active/<hostname>/<log-files>`

**Current encryption:** AWS KMS server-side encryption with a specific key ID.

**Current exclusions:** Files matching `*.container.[1-9]*` (rotated files) are excluded from sync.

---

## Target State

Split into two containers within the same ECS Fargate task:

### Container 1: Middleware (existing, modified)
- Runs Glassfish application server (unchanged)
- Runs logrotate on a schedule (hourly sleep loop) — keeps log files from growing unbounded
- **Removes**: rclone config, rclone sync loop, rclone package dependency
- Writes logs to a shared volume mounted at the application's log directory

### Container 2: Log Sync Sidecar (new)
- Minimal container based on `public.ecr.aws/aws-cli/aws-cli:latest`
- Runs `aws s3 sync` in a loop every 15 minutes (configurable via `SYNC_INTERVAL` env var)
- Reads from the shared volume (mounted read-only)
- Ships logs to `s3://<S3_BUCKET>/active/<hostname>/<files>`
- Applies KMS encryption (`--sse aws:kms --sse-kms-key-id <KEY>`)
- Excludes rotated files (`--exclude "*.container.[1-9]*"`)
- Uses `--exact-timestamps` to detect files truncated by logrotate
- Traps SIGTERM/SIGINT to run a final sync before container exit (graceful shutdown)
- Marked as `essential: false` so sidecar failure doesn't kill the middleware

---

## Detailed Requirements

### 1. Create Sidecar Docker Image

**Base image:** `public.ecr.aws/aws-cli/aws-cli:latest`

**Entrypoint script (`sync-logs.sh`) must:**
- Accept configuration via environment variables:
  - `S3_BUCKET` (required) — target S3 bucket name
  - `KMS_KEY_ID` (required) — KMS key ARN/ID for server-side encryption
  - `SYNC_INTERVAL` (optional, default: 900 seconds / 15 minutes)
  - `LOG_PATH` (optional, default: `/logs`)
  - `S3_PREFIX` (optional, default: `active`) — prefix path in the S3 bucket
- Construct S3 destination as: `s3://${S3_BUCKET}/${S3_PREFIX}/$(hostname)`
- Run `aws s3 sync` with these flags:
  - `--sse aws:kms`
  - `--sse-kms-key-id "$KMS_KEY_ID"`
  - `--exclude "*.container.[1-9]*"`
  - `--exact-timestamps`
  - No `--delete` flag (never remove files from S3)
- Log start/end timestamps and exit codes for each sync cycle
- Trap `TERM` and `INT` signals → run one final sync → exit 0
- Loop: sync → sleep $SYNC_INTERVAL → repeat

**Dockerfile must:**
- Copy the sync script into the image
- Set it as executable
- Use the script as ENTRYPOINT

### 2. Modify Middleware Container Entrypoint

**Remove:**
- rclone config creation (`/etc/rclone/rclone.conf`)
- rclone package (if installed in Dockerfile, remove it to shrink image)
- The entire `while true; do rclone sync ... sleep 300; done` background loop

**Keep:**
- logrotate config creation (unchanged)
- logrotate execution — but decouple it from sync success. Run it on its own schedule:
  ```bash
  (while true; do sleep 3600; /usr/sbin/logrotate -v /etc/logrotate.conf; done) &
  ```
- Glassfish startup (unchanged)

### 3. Update ECS Task Definition

**Add shared volume:**
```json
"volumes": [{ "name": "logs-volume" }]
```

**Middleware container mount:**
```json
"mountPoints": [{
  "sourceVolume": "logs-volume",
  "containerPath": "<JAVA_PROPERTY_LOG_PATH value>"
}]
```
Note: The `containerPath` should be whatever `$JAVA_PROPERTY_LOG_PATH` resolves to (the directory where the app writes its 10 log files). If logs are written to multiple directories (e.g., Glassfish logs in `/opt/glassfish/domains/DOMAIN/logs/` AND property logs elsewhere), you may need multiple shared volumes or a single parent mount that covers all paths.

**Sidecar container definition:**
```json
{
  "name": "log-sync-sidecar",
  "image": "<ECR_URI_FOR_SIDECAR>",
  "mountPoints": [{
    "sourceVolume": "logs-volume",
    "containerPath": "/logs",
    "readOnly": true
  }],
  "environment": [
    { "name": "S3_BUCKET", "value": "<bucket-name>" },
    { "name": "KMS_KEY_ID", "value": "<kms-key-id>" },
    { "name": "SYNC_INTERVAL", "value": "900" },
    { "name": "LOG_PATH", "value": "/logs" }
  ],
  "essential": false,
  "cpu": 128,
  "memory": 256,
  "stopTimeout": 30,
  "dependsOn": [
    { "containerName": "middleware", "condition": "START" }
  ]
}
```

**`stopTimeout: 30`** — gives the sidecar 30 seconds to complete its final sync after receiving SIGTERM.

### 4. IAM Permissions

The **task role** (not execution role) needs S3 and KMS permissions since `aws s3 sync` runs at runtime, not during image pull:

```json
{
  "Effect": "Allow",
  "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::<BUCKET>",
    "arn:aws:s3:::<BUCKET>/*"
  ]
},
{
  "Effect": "Allow",
  "Action": ["kms:GenerateDataKey", "kms:Decrypt"],
  "Resource": "arn:aws:kms:us-east-1:<ACCOUNT>:key/<KEY_ID>"
}
```

If the task role already has these permissions (from the existing rclone setup), no changes needed.

### 5. S3 Lifecycle Policy

Since `aws s3 sync` without `--delete` accumulates objects over time, add a lifecycle rule to auto-expire old logs:

```json
{
  "Rules": [{
    "ID": "expire-active-logs",
    "Filter": { "Prefix": "active/" },
    "Status": "Enabled",
    "Expiration": { "Days": 30 }
  }]
}
```

Adjust retention period to match your requirements.

### 6. Log Path Considerations

The current setup syncs `$JAVA_PROPERTY_LOG_PATH` which contains:
- `*.container` files
- Various `.log` files from Glassfish domains

If logs live in **multiple directories** that aren't under a single parent:
- Option A: Mount the common parent directory as the shared volume
- Option B: Use multiple shared volumes (one per log directory)
- Option C: Symlink all log files into a single directory (add to middleware entrypoint)

Determine which approach works for your directory layout.

---

## Testing & Verification

### Before Production Deploy

1. **Build sidecar image** → push to ECR
2. **Deploy to staging ECS cluster** with updated task definition
3. **Verify file sync:**
   - Exec into middleware container, check logs are being written
   - Check S3 bucket: files should appear under `active/<task-id>/`
   - Download a file from S3 and compare to source — should match
4. **Verify KMS encryption:**
   - Check S3 object metadata: `ServerSideEncryption: aws:kms`, `SSEKMSKeyId` matches
5. **Verify exclusion:**
   - Confirm `*.container.1`, `*.container.2` etc. do NOT appear in S3
6. **Verify logrotate interaction:**
   - Wait for logrotate to run (or trigger manually: `logrotate -f /etc/logrotate.conf`)
   - Confirm next sync uploads the truncated file correctly (not stale)
   - `--exact-timestamps` should handle this — verify file in S3 reflects post-rotation content
7. **Verify graceful shutdown:**
   - Stop the ECS task
   - Check S3 object timestamps — final objects should have timestamps close to task stop time
   - Check sidecar logs in CloudWatch for "Caught signal, running final sync" message
8. **Resource monitoring:**
   - Compare middleware container memory usage before/after (CloudWatch Container Insights)
   - Confirm sidecar stays well under 256MB allocation (expect 30-50MB during sync)
9. **Failure mode testing:**
   - Kill the sidecar container — verify middleware continues running (`essential: false`)
   - Verify ECS restarts the sidecar automatically (or the whole task, depending on your service config)

### Production Rollout

- Deploy during low-traffic window (middleware is a dependency for other services)
- Monitor CloudWatch for any middleware container OOM events or performance regression
- Verify SREs can download logs from S3 in the expected format and path structure
- Keep the old rclone-based task definition available for quick rollback

---

## Summary of Deliverables

| # | Deliverable | Owner |
|---|-------------|-------|
| 1 | Sidecar Dockerfile + sync-logs.sh | Engineer |
| 2 | ECR repository for sidecar image | Infra/Engineer |
| 3 | Updated middleware entrypoint (remove rclone, decouple logrotate) | Engineer |
| 4 | Updated ECS task definition (sidecar + shared volume) | Engineer |
| 5 | IAM policy review (confirm task role has s3/kms perms) | Engineer |
| 6 | S3 lifecycle policy for log expiration | Engineer |
| 7 | Staging deployment + verification | Engineer |
| 8 | Production deployment + monitoring | Engineer + SRE |
