#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-pixtools}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

echo "Hunting for the running K3s server..." >&2

# Find the running instance ID. No silent failures allowed.
INSTANCE_ID=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:Project,Values=${PROJECT}" \
    "Name=tag:Environment,Values=${ENVIRONMENT}" \
    "Name=tag:Role,Values=k3s-server" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[] | sort_by(@, &LaunchTime) | [-1].InstanceId" \
  --output text)

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "FATAL: Could not find a running K3s server." >&2
  exit 1
fi

echo "Success! Found active node: ${INSTANCE_ID}" >&2

# Output the ID so the GitHub Action can capture it
echo "${INSTANCE_ID}"