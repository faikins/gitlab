#!/bin/sh
while true; do
  echo "Starting rclone sync at $(date)"
  rclone sync /app/logs s3://my-s3-log-bucket --log-file=/app/rclone.log --log-level INFO
  echo "Finished rclone sync at $(date). Sleeping for 5 minutes..."
  sleep 300
done
