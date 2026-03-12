#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${1:?Usage: $0 <cluster> <service> [minutes-back] [log-group]}"
SERVICE="${2:?Usage: $0 <cluster> <service> [minutes-back] [log-group]}"
MINUTES_BACK="${3:-60}"
LOG_GROUP="${4:-/aws/ecs/containertaskdefinition}"

# Change this if you ever need a different region
REGION="us-east-1"

# FIX 2: validate MINUTES_BACK is numeric before arithmetic
if ! [[ "$MINUTES_BACK" =~ ^[0-9]+$ ]]; then
  echo "ERROR: minutes-back must be a positive integer, got: '$MINUTES_BACK'"
  exit 1
fi

START_MS=$(( ($(date +%s) - MINUTES_BACK * 60) * 1000 ))

# Derive container name: strip leading "<number>-" and trailing "-ecs-fargate"
# 11122233-sustain-ui-be-dark-prod-ecs-fargate → sustain-ui-be-dark-prod
CONTAINER_NAME="${CLUSTER#*-}"
CONTAINER_NAME="${CONTAINER_NAME%-ecs-fargate}"

# Derive task definition: replace trailing "-ecs-fargate" with "-task-definition"
# 11122233-sustain-ui-be-dark-prod-ecs-fargate → 11122233-sustain-ui-be-dark-prod-task-definition
TASK_DEF="${CLUSTER%-ecs-fargate}-task-definition"

# FireLens stream pattern: ecs/<container-name>-firelens-<task-id>
STREAM_PREFIX="ecs/${CONTAINER_NAME}-firelens"

echo "======================================================"
echo "Cluster      : $CLUSTER"
echo "Service      : $SERVICE"
echo "Region       : $REGION"
echo "Container    : $CONTAINER_NAME    (derived)"
echo "Task def     : $TASK_DEF          (derived)"
echo "Log group    : $LOG_GROUP"
echo "Stream prefix: $STREAM_PREFIX"
echo "Time window  : last $MINUTES_BACK minutes"
echo "======================================================"

# FIX 3: verify task definition with a clear error if AWS call itself fails
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

# FIX 4: capture event count and report if empty
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
