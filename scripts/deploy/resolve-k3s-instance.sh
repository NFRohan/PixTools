#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT is required}"
WAIT_FOR_SSM_ONLINE="${WAIT_FOR_SSM_ONLINE:-true}"
SSM_READY_TIMEOUT_SECONDS="${SSM_READY_TIMEOUT_SECONDS:-300}"
SSM_READY_POLL_SECONDS="${SSM_READY_POLL_SECONDS:-10}"

resolve_running_instance_id() {
  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:Name,Values=pixtools-${ENVIRONMENT}-k3s*" \
      "Name=instance-state-name,Values=running" \
    --query "reverse(sort_by(Reservations[].Instances[], &LaunchTime))[0].InstanceId" \
    --output text 2>/dev/null
}

wait_for_ssm_online() {
  local instance_id="$1"
  local elapsed=0
  local ping_status=""

  while (( elapsed < SSM_READY_TIMEOUT_SECONDS )); do
    ping_status="$(
      aws ssm describe-instance-information \
        --region "${AWS_REGION}" \
        --filters "Key=InstanceIds,Values=${instance_id}" \
        --query "InstanceInformationList[0].PingStatus" \
        --output text 2>/dev/null || true
    )"

    if [[ "${ping_status}" == "Online" ]]; then
      return 0
    fi

    sleep "${SSM_READY_POLL_SECONDS}"
    elapsed=$((elapsed + SSM_READY_POLL_SECONDS))
  done

  return 1
}

instance_id="$(resolve_running_instance_id)"
if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
  echo "No running K3s instance found for environment ${ENVIRONMENT}." >&2
  exit 1
fi

if [[ "${WAIT_FOR_SSM_ONLINE}" == "true" ]]; then
  if ! wait_for_ssm_online "${instance_id}"; then
    echo "K3s instance ${instance_id} is running but SSM is not Online after ${SSM_READY_TIMEOUT_SECONDS}s." >&2
    exit 1
  fi
fi

echo "${instance_id}"
