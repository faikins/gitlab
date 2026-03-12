#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${1:?Usage: $0 <cluster> <service> [region] [minutes-back] [container-name] }"
SERVICE="${2:?Usage: $0 <cluster> <service> [region] [minutes-back] [container-name] }"
REGION="${3:-us-east-1}"
MINUTES_BACK="${4:-60}"
CONTAINER_FILTER="${5:-}"
START_MS=$(( ($(date +%s) - MINUTES_BACK*60) * 1000 ))

# 1) Get task definition ARN from the ECS service
TASK_DEF=$(aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region "$REGION" \
  --query 'services[0].taskDefinition' \
  --output text)

if [[ -z "$TASK_DEF" || "$TASK_DEF" == "None" ]]; then
  echo "Could not find task definition for service=$SERVICE cluster=$CLUSTER region=$REGION"
  exit 1
fi
echo "Task definition: $TASK_DEF"
echo

# 2) Get container definitions as raw JSON, then extract fields with jq
# FIX: Removed the broken --query with dotted nested paths; use --output json + jq instead
CONTAINERS_JSON=$(aws ecs describe-task-definition \
  --task-definition "$TASK_DEF" \
  --region "$REGION" \
  --output json \
  | jq '[.taskDefinition.containerDefinitions[] | {
      name:         .name,
      logGroup:     (.logConfiguration.options."awslogs-group"     // ""),
      streamPrefix: (.logConfiguration.options."awslogs-stream-prefix" // "")
    }]')

echo "$CONTAINERS_JSON" | jq -c '.[]' | while read -r row; do
  NAME=$(echo "$row" | jq -r '.name')
  LOG_GROUP=$(echo "$row" | jq -r '.logGroup // empty')
  STREAM_PREFIX=$(echo "$row" | jq -r '.streamPrefix // empty')

  if [[ -n "$CONTAINER_FILTER" && "$NAME" != "$CONTAINER_FILTER" ]]; then
    continue
  fi

  if [[ -z "$LOG_GROUP" ]]; then
    echo "Skipping container '$NAME' because no awslogs-group is configured."
    continue
  fi

  echo "======================================================"
  echo "Container    : $NAME"
  echo "Log group    : $LOG_GROUP"
  echo "Stream prefix: $STREAM_PREFIX"
  echo "Time window  : last $MINUTES_BACK minutes"
  echo "======================================================"

  if [[ -n "$STREAM_PREFIX" ]]; then
    aws logs filter-log-events \
      --log-group-name "$LOG_GROUP" \
      --log-stream-name-prefix "${STREAM_PREFIX}/${NAME}" \
      --start-time "$START_MS" \
      --region "$REGION" \
      --output json | jq -r '
        .events[]? |
        "\(.timestamp/1000 | strftime("%Y-%m-%d %H:%M:%S"))  \(.logStreamName)\n\(.message)\n"
      '
  else
    aws logs filter-log-events \
      --log-group-name "$LOG_GROUP" \
      --start-time "$START_MS" \
      --region "$REGION" \
      --output json | jq -r '
        .events[]? |
        select(.logStreamName | contains("'"$NAME"'")) |
        "\(.timestamp/1000 | strftime("%Y-%m-%d %H:%M:%S"))  \(.logStreamName)\n\(.message)\n"
      '
  fi
  echo
done
