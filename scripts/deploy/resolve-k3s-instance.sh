#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT is required}"
WAIT_FOR_SSM_ONLINE="${WAIT_FOR_SSM_ONLINE:-true}"
SSM_READY_TIMEOUT_SECONDS="${SSM_READY_TIMEOUT_SECONDS:-900}"
SSM_READY_POLL_SECONDS="${SSM_READY_POLL_SECONDS:-10}"

resolve_running_instance_ids() {
  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:Name,Values=pixtools-${ENVIRONMENT}-k3s*" \
      "Name=instance-state-name,Values=running" \
    --query "reverse(sort_by(Reservations[].Instances[], &LaunchTime))[].InstanceId" \
    --output text 2>/dev/null || true
}

get_ping_status() {
  local instance_id="$1"
  aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || true
}

resolve_online_instance_id() {
  local elapsed=0
  local instance_ids_text=""
  local -a instance_ids=()
  local status_lines=""

  while (( elapsed < SSM_READY_TIMEOUT_SECONDS )); do
    instance_ids_text="$(resolve_running_instance_ids)"
    if [[ -z "${instance_ids_text}" || "${instance_ids_text}" == "None" ]]; then
      sleep "${SSM_READY_POLL_SECONDS}"
      elapsed=$((elapsed + SSM_READY_POLL_SECONDS))
      continue
    fi

    read -r -a instance_ids <<<"${instance_ids_text}"
    status_lines=""
    for instance_id in "${instance_ids[@]}"; do
      ping_status="$(get_ping_status "${instance_id}")"
      status_lines="${status_lines}${instance_id}:${ping_status:-Unknown} "
      if [[ "${ping_status}" == "Online" ]]; then
        echo "${instance_id}"
        return 0
      fi
    done

    if (( elapsed % 60 == 0 )); then
      echo "Waiting for SSM Online (${elapsed}s): ${status_lines}" >&2
    fi

    sleep "${SSM_READY_POLL_SECONDS}"
    elapsed=$((elapsed + SSM_READY_POLL_SECONDS))
  done

  return 1
}

instance_ids_text="$(resolve_running_instance_ids)"
if [[ -z "${instance_ids_text}" || "${instance_ids_text}" == "None" ]]; then
  echo "No running K3s instance found for environment ${ENVIRONMENT}." >&2
  exit 1
fi

if [[ "${WAIT_FOR_SSM_ONLINE}" == "true" ]]; then
  if ! instance_id="$(resolve_online_instance_id)"; then
    echo "No running K3s instance reached SSM Online after ${SSM_READY_TIMEOUT_SECONDS}s." >&2
    exit 1
  fi
  echo "${instance_id}"
  exit 0
fi

read -r instance_id _ <<<"${instance_ids_text}"
echo "${instance_id}"
