#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${1:?Usage: $0 <cluster> <service> [minutes-back]}"
SERVICE="${2:?Usage: $0 <cluster> <service> [minutes-back]}"
MINUTES_BACK="${3:-60}"

# Change this if you ever need a different region
REGION="us-east-1"

# FIX: validate MINUTES_BACK is numeric before arithmetic
if ! [[ "$MINUTES_BACK" =~ ^[0-9]+$ ]]; then
  echo "ERROR: minutes-back must be a positive integer, got: '$MINUTES_BACK'"
  exit 1
fi

START_MS=$(( ($(date +%s) - MINUTES_BACK * 60) * 1000 ))

# Derive container name: strip leading "<number>-" and trailing "-ecs-fargate"
CONTAINER_NAME="${CLUSTER#*-}"
CONTAINER_NAME="${CONTAINER_NAME%-ecs-fargate}"

# Derive task definition: replace trailing "-ecs-fargate" with "-task-definition"
TASK_DEF="${CLUSTER%-ecs-fargate}-task-definition"

# FireLens stream pattern: ecs/<container-name>-firelens-<task-id>
STREAM_PREFIX="ecs/${CONTAINER_NAME}-firelens"

# Auto-discover log group — search for /ecs log groups, prefer one matching
# the container name, fall back to the first /ecs group found
echo "Discovering log group for container '$CONTAINER_NAME'..."
LOG_GROUP=$(aws logs describe-log-groups \
  --region "$REGION" \
  --query 'logGroups[*].logGroupName' \
  --output json | \
  jq -r --arg container "$CONTAINER_NAME" '
    # First preference: log group name contains the container name
    (map(select(contains($container))) | first) //
    # Second preference: any /ecs log group
    (map(select(startswith("/ecs"))) | first) //
    # Third preference: any /aws/ecs log group
    (map(select(startswith("/aws/ecs"))) | first) //
    empty
  ')

if [[ -z "$LOG_GROUP" ]]; then
  echo "ERROR: Could not auto-discover a log group for container '$CONTAINER_NAME'."
  echo "       Check that FireLens is configured and logs exist in CloudWatch."
  exit 1
fi
echo "Discovered log group: $LOG_GROUP"

echo "======================================================"
echo "Cluster      : $CLUSTER"
echo "Service      : $SERVICE"
echo "Region       : $REGION"
echo "Container    : $CONTAINER_NAME    (derived)"
echo "Task def     : $TASK_DEF          (derived)"
echo "Log group    : $LOG_GROUP         (discovered)"
echo "Stream prefix: $STREAM_PREFIX"
echo "Time window  : last $MINUTES_BACK minutes"
echo "======================================================"

# Verify task definition exists
echo "Verifying task definition..."
if ! aws ecs describe-task-definition \
     --task-definition "$TASK_DEF" \
     --region "$REGION" \
     --query 'taskDefinition.taskDefinitionArn' \
     --output text 2>/dev/null; then
  echo "WARNING: Could not verify task definition '$TASK_DEF' — check cluster name or AWS credentials."
  echo "         Proceeding with log fetch anyway..."
fi
echo ""

# Fetch logs and report if empty
echo "Fetching logs..."
RESULTS=$(aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name-prefix "$STREAM_PREFIX" \
  --start-time "$START_MS" \
  --region "$REGION" \
  --output json)

EVENT_COUNT=$(echo "$RESULTS" | jq '[.events[]?] | length')

if [[ "$EVENT_COUNT" -eq 0 ]]; then
  echo "No log events found for container '$CONTAINER_NAME' in the last $MINUTES_BACK minutes."
  echo "Try increasing the time window: $0 $CLUSTER $SERVICE 120"
  exit 0
fi

echo "Found $EVENT_COUNT log events:"
echo ""
echo "$RESULTS" | jq -r '
  .events[]? |
  "\(.timestamp/1000 | strftime("%Y-%m-%d %H:%M:%S"))  \(.logStreamName)\n\(.message)\n"
'
