#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <instance-id> <command>" >&2
  exit 1
fi

INSTANCE_ID="$1"
COMMAND="$2"
REGION="${AWS_REGION:-us-east-1}"
PARAMETERS_JSON="$(jq -cn --arg cmd "${COMMAND}" '{commands: [$cmd]}')"

COMMAND_ID="$(
  aws ssm send-command \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "PixTools deployment command" \
    --parameters "${PARAMETERS_JSON}" \
    --query "Command.CommandId" \
    --output text
)"

echo "Sent command ${COMMAND_ID} to ${INSTANCE_ID}" >&2

get_invocation_json() {
  aws ssm get-command-invocation \
    --region "${REGION}" \
    --command-id "${COMMAND_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --output json 2>/dev/null || true
}

print_failure_details() {
  local invocation_json
  local status_details
  local response_code
  local stdout_content
  local stderr_content

  invocation_json="$(get_invocation_json)"
  status_details="$(jq -r '.StatusDetails // empty' <<<"${invocation_json}")"
  response_code="$(jq -r '.ResponseCode // empty' <<<"${invocation_json}")"
  stdout_content="$(jq -r '.StandardOutputContent // ""' <<<"${invocation_json}")"
  stderr_content="$(jq -r '.StandardErrorContent // ""' <<<"${invocation_json}")"

  if [[ -n "${status_details}" ]]; then
    echo "StatusDetails: ${status_details}" >&2
  fi
  if [[ -n "${response_code}" && "${response_code}" != "None" ]]; then
    echo "ResponseCode: ${response_code}" >&2
  fi

  if [[ -n "${stderr_content}" ]]; then
    echo "----- SSM STDERR -----" >&2
    echo "${stderr_content}" >&2
  fi
  if [[ -n "${stdout_content}" ]]; then
    echo "----- SSM STDOUT -----" >&2
    echo "${stdout_content}" >&2
  fi

}

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
      print_failure_details
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
print_failure_details
exit 1
