#!/usr/bin/env bash
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
  # Guard against accidental "grafana.net./otlp" style URLs.
  value="${value//.net.\//.net/}"
  printf '%s' "${value}"
}

node_count() {
  kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '
}

wait_for_nodes() {
  local timeout_seconds="${1:-120}"
  local elapsed=0
  local count=0

  while (( elapsed < timeout_seconds )); do
    count="$(node_count)"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

ensure_cluster_has_nodes() {
  if wait_for_nodes 60; then
    return 0
  fi

  log "No nodes registered yet; restarting k3s service to recover control-plane/agent state"
  systemctl restart k3s || true

  if wait_for_nodes 180; then
    return 0
  fi

  log "Cluster still has zero registered nodes after restart"
  systemctl --no-pager --full status k3s || true
  journalctl -u k3s -n 120 --no-pager || true
  return 1
}

sync_manifests() {
  log "Syncing manifests from s3://${MANIFEST_BUCKET}/${MANIFEST_PREFIX}"
  mkdir -p "${MANIFEST_DIR}"
  aws s3 sync "s3://${MANIFEST_BUCKET}/${MANIFEST_PREFIX}" "${MANIFEST_DIR}" --delete --region "${AWS_REGION}"
}

refresh_ecr_pull_secret() {
  log "Refreshing ECR pull secret"
  local account_id
  local ecr_registry
  local ecr_password

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

sync_runtime_materialized_config() {
  log "Syncing runtime secrets/config from SSM"

  local database_url
  local redis_url
  local rabbitmq_url
  local aws_s3_bucket
  local api_key
  local rabbitmq_username
  local rabbitmq_password
  local idempotency_ttl
  local webhook_fail_threshold
  local webhook_reset_timeout
  local stack_id
  local logs_user
  local metrics_user
  local traces_user
  local grafana_key
  local logs_url
  local metrics_url
  local traces_url

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

label_cluster_nodes() {
  log "Labeling cluster nodes for app/infra placement"

  local -a live_nodes=()
  local node_found=false

  while IFS=$'\t' read -r node_name provider_id; do
    local instance_id=""
    local instance_state

    [[ -z "${node_name}" ]] && continue

    if [[ "${provider_id}" == *"/i-"* ]]; then
      instance_id="${provider_id##*/}"
    fi

    if [[ -n "${instance_id}" ]]; then
      instance_state="$(
        aws ec2 describe-instances \
          --region "${AWS_REGION}" \
          --instance-ids "${instance_id}" \
          --query "Reservations[0].Instances[0].State.Name" \
          --output text 2>/dev/null || true
      )"
      if [[ "${instance_state}" != "running" && "${instance_state}" != "pending" ]]; then
        log "Deleting stale kubernetes node object ${node_name} (instance ${instance_id} state=${instance_state:-unknown})"
        kubectl delete node "${node_name}" --ignore-not-found=true >/dev/null || true
        continue
      fi
    fi

    live_nodes+=("${node_name}")
    node_found=true
  done < <(kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.spec.providerID // "")] | @tsv')

  if [[ "${node_found}" != "true" || "${#live_nodes[@]}" -eq 0 ]]; then
    # Node registration can lag briefly after k3s restart.
    if wait_for_nodes 60; then
      while IFS=$'\t' read -r node_name _; do
        [[ -n "${node_name}" ]] && live_nodes+=("${node_name}")
      done < <(kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.spec.providerID // "")] | @tsv')
    fi
  fi

  if [[ "${#live_nodes[@]}" -eq 0 ]]; then
    log "No live nodes found in cluster"
    return 1
  fi

  # Default to shared-node placement in demo environments. This avoids hard
  # scheduling failures during node re-registration or single-node operation.
  for node in "${live_nodes[@]}"; do
    kubectl label node "${node}" \
      pixtools-workload-infra=true \
      pixtools-workload-app=true \
      --overwrite >/dev/null
  done

  log "Infra nodes: ${live_nodes[*]}"
  log "App nodes: ${live_nodes[*]}"
  kubectl get nodes -L pixtools-workload-infra,pixtools-workload-app || true
}

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

recover_rabbitmq_volume_affinity_if_needed() {
  if ! kubectl -n "${NAMESPACE}" get pod rabbitmq-0 >/dev/null 2>&1; then
    return 0
  fi

  if ! kubectl -n "${NAMESPACE}" describe pod rabbitmq-0 | grep -qi "volume node affinity conflict"; then
    return 0
  fi

  log "RabbitMQ has a volume node affinity conflict; recreating claim and volume"

  local pv_name
  pv_name="$(kubectl -n "${NAMESPACE}" get pvc rabbitmq-data-rabbitmq-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"

  kubectl -n "${NAMESPACE}" delete pod rabbitmq-0 --ignore-not-found=true >/dev/null || true
  kubectl -n "${NAMESPACE}" delete pvc rabbitmq-data-rabbitmq-0 --ignore-not-found=true >/dev/null || true
  if [[ -n "${pv_name}" ]]; then
    kubectl delete pv "${pv_name}" --ignore-not-found=true >/dev/null || true
  fi

  kubectl apply -f "${MANIFEST_DIR}/rabbitmq/service.yaml"
  kubectl apply -f "${MANIFEST_DIR}/rabbitmq/statefulset.yaml"
}

wait_for_rollouts() {
  log "Waiting for core workload rollouts"
  kubectl -n "${NAMESPACE}" rollout status deployment/redis --timeout=180s
  if ! kubectl -n "${NAMESPACE}" rollout status statefulset/rabbitmq --timeout=180s; then
    log "RabbitMQ rollout timed out; retrying after affinity recovery"
    recover_rabbitmq_volume_affinity_if_needed
    kubectl -n "${NAMESPACE}" rollout status statefulset/rabbitmq --timeout=300s
  fi
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-api --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-worker-standard --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-worker-ml --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/pixtools-beat --timeout=180s

  if ! kubectl -n "${NAMESPACE}" rollout status deployment/alloy --timeout=180s; then
    log "Alloy rollout did not complete; continuing because it is non-blocking for core processing"
  fi
}

main() {
  log "Starting cluster reconciliation"
  sync_manifests
  refresh_ecr_pull_secret
  sync_runtime_materialized_config
  ensure_cluster_has_nodes
  label_cluster_nodes
  apply_manifests
  recover_rabbitmq_volume_affinity_if_needed
  wait_for_rollouts
  log "Cluster reconciliation complete"
}

main "$@"
