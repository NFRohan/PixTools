#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <instance-id> <command>" >&2
  exit 1
fi

INSTANCE_ID="$1"
COMMAND="$2"
REGION="${AWS_REGION:-us-east-1}"

COMMAND_ID="$(
  aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "PixTools deployment command" \
    --parameters "commands=${COMMAND}" \
    --query "Command.CommandId" \
    --output text
)"

echo "Sent command ${COMMAND_ID} to ${INSTANCE_ID}"

for _ in {1..120}; do
  STATUS="$(
    aws ssm get-command-invocation \
      --region "${REGION}" \
      --command-id "${COMMAND_ID}" \
      --instance-id "${INSTANCE_ID}" \
      --query "Status" \
      --output text 2>/dev/null || true
  )"

  case "${STATUS}" in
    Success)
      aws ssm get-command-invocation \
        --region "${REGION}" \
        --command-id "${COMMAND_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --query "StandardOutputContent" \
        --output text
      exit 0
      ;;
    Failed|TimedOut|Cancelled|Cancelling)
      echo "Command failed with status: ${STATUS}" >&2
      aws ssm get-command-invocation \
        --region "${REGION}" \
        --command-id "${COMMAND_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --query "StandardErrorContent" \
        --output text >&2 || true
      exit 1
      ;;
    InProgress|Pending|Delayed|"")
      sleep 5
      ;;
    *)
      sleep 5
      ;;
  esac
done

echo "Timed out waiting for SSM command completion" >&2
exit 1

