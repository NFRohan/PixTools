#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <instance-id> <command>" >&2
  exit 1
fi

INSTANCE_ID="$1"
COMMAND="$2"
REGION="${AWS_REGION:-us-east-1}"
WAIT_TIMEOUT_SECONDS="${SSM_WAIT_TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${SSM_POLL_INTERVAL_SECONDS:-5}"
PENDING_TIMEOUT_SECONDS="${SSM_PENDING_TIMEOUT_SECONDS:-300}"
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

cancel_inflight_command() {
  aws ssm cancel-command \
    --region "${REGION}" \
    --command-id "${COMMAND_ID}" >/dev/null 2>&1 || true
}

if ! [[ "${WAIT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( WAIT_TIMEOUT_SECONDS <= 0 )); then
  echo "Invalid SSM_WAIT_TIMEOUT_SECONDS: ${WAIT_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if ! [[ "${POLL_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL_SECONDS <= 0 )); then
  echo "Invalid SSM_POLL_INTERVAL_SECONDS: ${POLL_INTERVAL_SECONDS}" >&2
  exit 1
fi

if ! [[ "${PENDING_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( PENDING_TIMEOUT_SECONDS < 0 )); then
  echo "Invalid SSM_PENDING_TIMEOUT_SECONDS: ${PENDING_TIMEOUT_SECONDS}" >&2
  exit 1
fi

elapsed=0
pending_elapsed=0
last_status=""

while (( elapsed < WAIT_TIMEOUT_SECONDS )); do
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
    Pending)
      pending_elapsed=$((pending_elapsed + POLL_INTERVAL_SECONDS))
      if (( PENDING_TIMEOUT_SECONDS > 0 && pending_elapsed >= PENDING_TIMEOUT_SECONDS )); then
        echo "SSM command ${COMMAND_ID} stayed Pending for ${pending_elapsed}s; cancelling as undeliverable/stuck" >&2
        cancel_inflight_command
        sleep 2
        print_failure_details
        exit 1
      fi
      if [[ "${STATUS}" != "${last_status}" ]] || (( elapsed % 60 == 0 )); then
        echo "SSM command ${COMMAND_ID} status=${STATUS} elapsed=${elapsed}s pending=${pending_elapsed}s" >&2
        last_status="${STATUS}"
      fi
      sleep "${POLL_INTERVAL_SECONDS}"
      elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
      ;;
    InProgress|Delayed|"")
      pending_elapsed=0
      if [[ "${STATUS}" != "${last_status}" ]] || (( elapsed % 60 == 0 )); then
        echo "SSM command ${COMMAND_ID} status=${STATUS:-Unknown} elapsed=${elapsed}s" >&2
        last_status="${STATUS}"
      fi
      sleep "${POLL_INTERVAL_SECONDS}"
      elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
      ;;
    *)
      echo "SSM command ${COMMAND_ID} status=${STATUS} elapsed=${elapsed}s" >&2
      sleep "${POLL_INTERVAL_SECONDS}"
      elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
      ;;
  esac
done

echo "Timed out waiting for SSM command completion after ${WAIT_TIMEOUT_SECONDS}s" >&2
echo "Attempting to cancel SSM command ${COMMAND_ID}" >&2
cancel_inflight_command
sleep 3
print_failure_details
exit 1
