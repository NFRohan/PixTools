#!/usr/bin/env bash
# Resolve the K3s SERVER instance ID for CD operations.
# Filters by Role=k3s-server tag, running state, and waits for SSM Online status.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-pixtools}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT is required}"
WAIT_FOR_SSM_ONLINE="${WAIT_FOR_SSM_ONLINE:-true}"
SSM_READY_TIMEOUT_SECONDS="${SSM_READY_TIMEOUT_SECONDS:-900}"
SSM_READY_POLL_SECONDS="${SSM_READY_POLL_SECONDS:-10}"

resolve_server_instance_id() {
  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:Project,Values=${PROJECT}" \
      "Name=tag:Environment,Values=${ENVIRONMENT}" \
      "Name=tag:Role,Values=k3s-server" \
      "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[] | sort_by(@, &LaunchTime) | [-1].InstanceId" \
    --output text 2>/dev/null || true
}

get_ping_status() {
  aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=$1" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || true
}

wait_for_online() {
  local elapsed=0
  while (( elapsed < SSM_READY_TIMEOUT_SECONDS )); do
    local instance_id
    instance_id="$(resolve_server_instance_id)"

    if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
      sleep "${SSM_READY_POLL_SECONDS}"
      elapsed=$((elapsed + SSM_READY_POLL_SECONDS))
      continue
    fi

    local status
    status="$(get_ping_status "${instance_id}")"
    if [[ "${status}" == "Online" ]]; then
      echo "${instance_id}"
      return 0
    fi

    if (( elapsed % 60 == 0 )); then
      echo "Waiting for server ${instance_id} SSM Online (${elapsed}s, status=${status:-Unknown})" >&2
    fi

    sleep "${SSM_READY_POLL_SECONDS}"
    elapsed=$((elapsed + SSM_READY_POLL_SECONDS))
  done

  return 1
}

# --- Main ---
instance_id="$(resolve_server_instance_id)"
if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
  echo "No running K3s server instance found (Project=${PROJECT}, Environment=${ENVIRONMENT})." >&2
  exit 1
fi

if [[ "${WAIT_FOR_SSM_ONLINE}" == "true" ]]; then
  if ! instance_id="$(wait_for_online)"; then
    echo "K3s server instance did not reach SSM Online after ${SSM_READY_TIMEOUT_SECONDS}s." >&2
    exit 1
  fi
fi

echo "${instance_id}"
