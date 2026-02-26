#!/usr/bin/env bash
# Cluster reconciliation script for two-node K3s architecture.
# Runs on the K3s SERVER node via SSM during CD deployments.
#
# Responsibilities:
#   1. Sync manifests from S3
#   2. Refresh ECR pull secret
#   3. Sync runtime config from SSM → K8s secrets/configmaps
#   4. Label nodes by role (server→infra, agent→app)
#   5. Apply manifests in deterministic order
#   6. Wait for rollouts
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-pixtools}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT is required}"
MANIFEST_BUCKET="${MANIFEST_BUCKET:?MANIFEST_BUCKET is required}"
MANIFEST_PREFIX="${MANIFEST_PREFIX:?MANIFEST_PREFIX is required}"
NAMESPACE="${NAMESPACE:-pixtools}"
MANIFEST_DIR="${MANIFEST_DIR:-/opt/pixtools/manifests}"
SSM_PREFIX="/${PROJECT}/${ENVIRONMENT}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

get_param() {
  aws ssm get-parameter \
    --region "${AWS_REGION}" \
    --name "$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text
}

get_param_optional() {
  aws ssm get-parameter \
    --region "${AWS_REGION}" \
    --name "$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || true
}

normalize_url() {
  local value="${1:-}"
  value="${value//.net.\///.net/}"
  printf '%s' "${value}"
}

# ============================================================
# 1. Sync manifests from S3
# ============================================================
sync_manifests() {
  log "Syncing manifests from s3://${MANIFEST_BUCKET}/${MANIFEST_PREFIX}"
  mkdir -p "${MANIFEST_DIR}"
  aws s3 sync "s3://${MANIFEST_BUCKET}/${MANIFEST_PREFIX}" "${MANIFEST_DIR}" --delete --region "${AWS_REGION}"
}

# ============================================================
# 2. Refresh ECR pull secret
# ============================================================
refresh_ecr_pull_secret() {
  log "Refreshing ECR pull secret"
  local account_id ecr_registry ecr_password

  account_id="$(aws sts get-caller-identity --query Account --output text --region "${AWS_REGION}")"
  ecr_registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  ecr_password="$(aws ecr get-login-password --region "${AWS_REGION}")"

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${NAMESPACE}" create secret docker-registry ecr-pull \
    --docker-server="${ecr_registry}" \
    --docker-username="AWS" \
    --docker-password="${ecr_password}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"ecr-pull"}]}' >/dev/null || true
}

# ============================================================
# 3. Sync runtime config from SSM → K8s secrets/configmaps
# ============================================================
sync_runtime_config() {
  log "Syncing runtime secrets/config from SSM"

  local database_url redis_url rabbitmq_url aws_s3_bucket api_key
  local rabbitmq_username rabbitmq_password
  local idempotency_ttl webhook_fail_threshold webhook_reset_timeout
  local stack_id logs_user metrics_user traces_user grafana_key
  local logs_url metrics_url traces_url

  database_url="$(get_param "${SSM_PREFIX}/database_url")"
  redis_url="$(get_param "${SSM_PREFIX}/redis_url")"
  rabbitmq_url="$(get_param "${SSM_PREFIX}/rabbitmq_url")"
  aws_s3_bucket="$(get_param "${SSM_PREFIX}/aws_s3_bucket")"
  api_key="$(get_param "${SSM_PREFIX}/api_key")"
  rabbitmq_username="$(get_param "${SSM_PREFIX}/rabbitmq_username")"
  rabbitmq_password="$(get_param "${SSM_PREFIX}/rabbitmq_password")"

  idempotency_ttl="$(get_param_optional "${SSM_PREFIX}/idempotency_ttl_seconds")"
  webhook_fail_threshold="$(get_param_optional "${SSM_PREFIX}/webhook_cb_fail_threshold")"
  webhook_reset_timeout="$(get_param_optional "${SSM_PREFIX}/webhook_cb_reset_timeout")"
  idempotency_ttl="${idempotency_ttl:-86400}"
  webhook_fail_threshold="${webhook_fail_threshold:-5}"
  webhook_reset_timeout="${webhook_reset_timeout:-60}"

  stack_id="$(get_param_optional "${SSM_PREFIX}/grafana_cloud_stack_id")"
  logs_user="$(get_param_optional "${SSM_PREFIX}/grafana_cloud_logs_user")"
  metrics_user="$(get_param_optional "${SSM_PREFIX}/grafana_cloud_metrics_user")"
  traces_user="$(get_param_optional "${SSM_PREFIX}/grafana_cloud_traces_user")"
  grafana_key="$(get_param_optional "${SSM_PREFIX}/grafana_cloud_api_key")"
  logs_url="$(normalize_url "$(get_param_optional "${SSM_PREFIX}/grafana_cloud_logs_url")")"
  metrics_url="$(normalize_url "$(get_param_optional "${SSM_PREFIX}/grafana_cloud_metrics_url")")"
  traces_url="$(normalize_url "$(get_param_optional "${SSM_PREFIX}/grafana_cloud_traces_url")")"

  logs_user="${logs_user:-${stack_id}}"
  metrics_user="${metrics_user:-${stack_id}}"
  traces_user="${traces_user:-${stack_id}}"

  kubectl -n "${NAMESPACE}" create secret generic pixtools-runtime \
    --from-literal=DATABASE_URL="${database_url}" \
    --from-literal=REDIS_URL="${redis_url}" \
    --from-literal=RABBITMQ_URL="${rabbitmq_url}" \
    --from-literal=AWS_S3_BUCKET="${aws_s3_bucket}" \
    --from-literal=API_KEY="${api_key}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic rabbitmq-auth \
    --from-literal=username="${rabbitmq_username}" \
    --from-literal=password="${rabbitmq_password}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create secret generic grafana-cloud \
    --from-literal=stack_id="${stack_id}" \
    --from-literal=logs_user="${logs_user}" \
    --from-literal=metrics_user="${metrics_user}" \
    --from-literal=traces_user="${traces_user}" \
    --from-literal=api_key="${grafana_key}" \
    --from-literal=logs_url="${logs_url}" \
    --from-literal=metrics_url="${metrics_url}" \
    --from-literal=traces_url="${traces_url}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${NAMESPACE}" create configmap pixtools-config \
    --from-literal=AWS_REGION="${AWS_REGION}" \
    --from-literal=IDEMPOTENCY_TTL_SECONDS="${idempotency_ttl}" \
    --from-literal=WEBHOOK_CB_FAIL_THRESHOLD="${webhook_fail_threshold}" \
    --from-literal=WEBHOOK_CB_RESET_TIMEOUT="${webhook_reset_timeout}" \
    --from-literal=OBSERVABILITY_ENABLED="true" \
    --from-literal=METRICS_ENABLED="true" \
    --from-literal=OTEL_EXPORTER_OTLP_ENDPOINT="http://alloy.pixtools.svc.cluster.local:4318" \
    --from-literal=OTEL_SERVICE_NAME_API="pixtools-api" \
    --from-literal=OTEL_SERVICE_NAME_WORKER="pixtools-worker" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# ============================================================
# 4. Label nodes by role
# ============================================================
label_nodes_by_role() {
  log "Labeling cluster nodes by role"

  while IFS=$'\t' read -r node_name provider_id; do
    [[ -z "${node_name}" ]] && continue

    local instance_id=""
    if [[ "${provider_id}" == *"/i-"* ]]; then
      instance_id="${provider_id##*/}"
    fi

    local role="unknown"
    if [[ -n "${instance_id}" ]]; then
      role="$(aws ec2 describe-tags \
        --region "${AWS_REGION}" \
        --filters "Name=resource-id,Values=${instance_id}" "Name=key,Values=Role" \
        --query "Tags[0].Value" \
        --output text 2>/dev/null || echo "unknown")"
    fi

    case "${role}" in
      k3s-server)
        kubectl label node "${node_name}" \
          pixtools-workload-infra=true \
          --overwrite >/dev/null
        # Remove app label if it was previously set
        kubectl label node "${node_name}" \
          pixtools-workload-app- \
          --overwrite >/dev/null 2>&1 || true
        log "  ${node_name} → infra (server)"
        ;;
      k3s-agent)
        kubectl label node "${node_name}" \
          pixtools-workload-app=true \
          --overwrite >/dev/null
        # Remove infra label if it was previously set
        kubectl label node "${node_name}" \
          pixtools-workload-infra- \
          --overwrite >/dev/null 2>&1 || true
        log "  ${node_name} → app (agent)"
        ;;
      *)
        log "  ${node_name} → unknown role '${role}', labeling as both (fallback)"
        kubectl label node "${node_name}" \
          pixtools-workload-infra=true \
          pixtools-workload-app=true \
          --overwrite >/dev/null
        ;;
    esac
  done < <(kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.spec.providerID // "")] | @tsv')
}

# ============================================================
# 5. Apply manifests in deterministic order
# ============================================================
apply_manifests() {
  log "Applying manifests in deterministic order"

  local ordered_files=(
    "${MANIFEST_DIR}/namespace.yaml"
    "${MANIFEST_DIR}/config/configmap.yaml"
    "${MANIFEST_DIR}/redis/service.yaml"
    "${MANIFEST_DIR}/redis/deployment.yaml"
    "${MANIFEST_DIR}/rabbitmq/service.yaml"
    "${MANIFEST_DIR}/rabbitmq/statefulset.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-rbac.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-configmap.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-service.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-deployment.yaml"
    "${MANIFEST_DIR}/api/service.yaml"
    "${MANIFEST_DIR}/api/deployment.yaml"
    "${MANIFEST_DIR}/api/hpa.yaml"
    "${MANIFEST_DIR}/workers/worker-standard.yaml"
    "${MANIFEST_DIR}/workers/worker-ml.yaml"
    "${MANIFEST_DIR}/workers/beat.yaml"
    "${MANIFEST_DIR}/ingress/ingress.yaml"
  )

  for file in "${ordered_files[@]}"; do
    if [[ -f "${file}" ]]; then
      kubectl apply -f "${file}"
    fi
  done
}

# ============================================================
# 6. Wait for rollouts
# ============================================================
wait_for_rollouts() {
  log "Waiting for workload rollouts"

  # Infra workloads (on server node — should always be available)
  kubectl -n "${NAMESPACE}" rollout status deployment/redis --timeout=120s
  kubectl -n "${NAMESPACE}" rollout status statefulset/rabbitmq --timeout=180s

  # App workloads (on agent node — may take longer if spot is being provisioned)
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-api --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-worker-standard --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-worker-ml --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-beat --timeout=180s

  # Monitoring (non-blocking)
  if ! kubectl -n "${NAMESPACE}" rollout status daemonset/alloy --timeout=120s; then
    log "Alloy rollout did not complete; non-blocking for core processing"
  fi
}

# ============================================================
# Main
# ============================================================
main() {
  log "Starting cluster reconciliation"
  sync_manifests
  refresh_ecr_pull_secret
  sync_runtime_config
  label_nodes_by_role
  apply_manifests
  wait_for_rollouts
  log "Cluster reconciliation complete"
}

main "$@"
