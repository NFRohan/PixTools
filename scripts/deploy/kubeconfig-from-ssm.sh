#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <instance-id>" >&2
  exit 1
fi

INSTANCE_ID="$1"
REGION="${AWS_REGION:-us-east-1}"

TMP_FILE="/tmp/k3s.yaml"

aws ssm send-command \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=sudo cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml" \
  >/dev/null

echo "Use SSM Session Manager port forwarding or direct node access to retrieve ${TMP_FILE} if needed."

