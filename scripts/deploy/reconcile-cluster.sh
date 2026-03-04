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

wait_for_apiserver() {
  local timeout_seconds="${1:-180}"
  local elapsed=0
  local interval=5

  while (( elapsed < timeout_seconds )); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log "K3s API server did not become ready within ${timeout_seconds}s"
  return 1
}

kubectl_apply_with_retry() {
  local file="$1"
  local max_attempts=6
  local attempt

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if kubectl apply --validate=false -f "${file}"; then
      return 0
    fi

    if (( attempt == max_attempts )); then
      break
    fi

    log "kubectl apply failed for ${file}; waiting for API server before retry ${attempt}/${max_attempts}"
    wait_for_apiserver 180
    sleep 5
  done

  log "kubectl apply failed permanently for ${file}"
  return 1
}

statefulset_storage_class() {
  local namespace="$1"
  local name="$2"

  kubectl -n "${namespace}" get statefulset "${name}" -o json | \
    jq -r '.spec.volumeClaimTemplates[0].spec.storageClassName // ""' 2>/dev/null || true
}

manifest_storage_class() {
  local file="$1"

  kubectl create --dry-run=client -f "${file}" -o json | \
    jq -r '.spec.volumeClaimTemplates[0].spec.storageClassName // ""' 2>/dev/null || true
}

rabbitmq_storage_migration_pending() {
  local file="$1"
  local current_storage_class=""
  local desired_storage_class=""

  if ! kubectl -n "${NAMESPACE}" get statefulset rabbitmq >/dev/null 2>&1; then
    return 1
  fi

  current_storage_class="$(statefulset_storage_class "${NAMESPACE}" rabbitmq)"
  desired_storage_class="$(manifest_storage_class "${file}")"

  [[ -n "${desired_storage_class}" ]] || return 1
  [[ "${current_storage_class}" != "${desired_storage_class}" ]]
}

apply_manifest_safely() {
  local file="$1"

  if [[ "${file}" == "${MANIFEST_DIR}/rabbitmq/statefulset.yaml" ]] && rabbitmq_storage_migration_pending "${file}"; then
    local current_storage_class=""
    local desired_storage_class=""
    current_storage_class="$(statefulset_storage_class "${NAMESPACE}" rabbitmq)"
    desired_storage_class="$(manifest_storage_class "${file}")"
    log "Skipping RabbitMQ StatefulSet apply: storageClass migration ${current_storage_class:-<unset>} -> ${desired_storage_class} requires controlled maintenance via scripts/deploy/migrate-rabbitmq-to-gp3.sh"
    return 0
  fi

  kubectl_apply_with_retry "${file}"
}

recover_keda_release_if_stuck() {
  local helm_status=""
  local stable_revision=""

  helm_status="$(
    helm status keda --namespace keda -o json 2>/dev/null | jq -r '.info.status // "unknown"' 2>/dev/null || echo "unknown"
  )"

  case "${helm_status}" in
    pending-install|pending-upgrade|pending-rollback)
      stable_revision="$(
        helm history keda --namespace keda -o json 2>/dev/null |
          jq -r '[.[] | select(.status == "deployed" or .status == "superseded")] | last | .revision // empty' 2>/dev/null || true
      )"

      if [[ -z "${stable_revision}" ]]; then
        log "KEDA Helm release is stuck (${helm_status}) but no stable revision was found for rollback"
        return 1
      fi

      log "Recovering stuck KEDA Helm release (${helm_status}) via rollback to revision ${stable_revision}"
      helm rollback keda "${stable_revision}" \
        --namespace keda \
        --wait \
        --timeout 180s >/dev/null
      ;;
  esac
}

install_keda() {
  local values_file="${MANIFEST_DIR}/autoscaling/keda-values.yaml"
  local max_attempts=12
  local attempt=1
  local helm_output=""
  local helm_status="unknown"
  local rc=0
  local recovered=false

  if [[ ! -f "${values_file}" ]]; then
    log "KEDA values file not found; skipping KEDA install"
    return
  fi

  log "Installing or upgrading KEDA"
  helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
  helm repo update kedacore >/dev/null
  recover_keda_release_if_stuck || true

  while (( attempt <= max_attempts )); do
    set +e
    helm_output="$(
      helm upgrade --install keda kedacore/keda \
        --namespace keda \
        --create-namespace \
        --version 2.19.0 \
        -f "${values_file}" \
        --wait \
        --timeout 180s 2>&1
    )"
    rc=$?
    set -e

    if (( rc == 0 )); then
      return 0
    fi

    if grep -q "another operation (install/upgrade/rollback) is in progress" <<<"${helm_output}"; then
      helm_status="$(
        helm status keda --namespace keda -o json 2>/dev/null | jq -r '.info.status // "unknown"' 2>/dev/null || echo "unknown"
      )"

      if [[ "${recovered}" == false && "${helm_status}" == pending-* ]]; then
        recover_keda_release_if_stuck || true
        recovered=true
      fi

      log "KEDA Helm release busy (status=${helm_status}); retrying ${attempt}/${max_attempts} in 15s"
      sleep 15
      attempt=$((attempt + 1))
      continue
    fi

    printf '%s\n' "${helm_output}" >&2
    return "${rc}"
  done

  printf '%s\n' "${helm_output}" >&2
  return 1
}

apply_keda_metrics_rbac_prereqs() {
  local rbac_file="${MANIFEST_DIR}/autoscaling/keda-metrics-rbac.yaml"

  if [[ ! -f "${rbac_file}" ]]; then
    return
  fi

  log "Applying KEDA metrics API RBAC prerequisites"
  kubectl_apply_with_retry "${rbac_file}"
}

install_aws_ebs_csi() {
  local values_file="${MANIFEST_DIR}/storage/aws-ebs-csi-values.yaml"

  if [[ ! -f "${values_file}" ]]; then
    log "AWS EBS CSI values file not found; skipping EBS CSI install"
    return
  fi

  log "Installing or upgrading AWS EBS CSI driver"
  helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver >/dev/null 2>&1 || true
  helm repo update aws-ebs-csi-driver >/dev/null

  helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    --namespace kube-system \
    --version 2.40.0 \
    -f "${values_file}" \
    --wait \
    --timeout 180s >/dev/null
}

tune_kube_system_control_plane_footprint() {
  if kubectl -n kube-system get deployment aws-load-balancer-controller >/dev/null 2>&1; then
    log "Scaling aws-load-balancer-controller to 1 replica on the infra node"
    kubectl -n kube-system scale deployment aws-load-balancer-controller --replicas=1 >/dev/null
    kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s >/dev/null || true
  fi
}

instance_state_for_node() {
  local provider_id="${1:-}"
  local instance_id=""
  if [[ "${provider_id}" == *"/i-"* ]]; then
    instance_id="${provider_id##*/}"
  fi

  if [[ -z "${instance_id}" ]]; then
    printf '%s' "unknown"
    return
  fi

  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text 2>/dev/null || printf '%s' "missing"
}

cleanup_stale_nodes() {
  log "Cleaning stale Kubernetes nodes"

  while IFS=$'\t' read -r node_name provider_id ready_status; do
    [[ -z "${node_name}" ]] && continue

    local instance_state
    instance_state="$(instance_state_for_node "${provider_id}")"
    if [[ "${ready_status}" != "True" && "${instance_state}" != "running" ]]; then
      log "  deleting stale node ${node_name} (instance state: ${instance_state})"
      kubectl delete node "${node_name}" --ignore-not-found=true >/dev/null || true
    fi
  done < <(kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.spec.providerID // ""), ((.status.conditions[] | select(.type == "Ready") | .status) // "Unknown")] | @tsv')
}

cleanup_stale_terminating_pods() {
  log "Force deleting stale terminating pods"

  while IFS= read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    log "  force deleting pod ${pod_name}"
    kubectl -n "${NAMESPACE}" delete pod "${pod_name}" --force --grace-period=0 >/dev/null || true
  done < <(kubectl -n "${NAMESPACE}" get pods -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name')
}

cleanup_deprecated_autoscalers() {
  if [[ -f "${MANIFEST_DIR}/autoscaling/worker-standard-scaledobject.yaml" ]]; then
    log "Removing deprecated worker-standard HPA in favor of KEDA"
    kubectl -n "${NAMESPACE}" delete hpa pixtools-worker-standard --ignore-not-found=true >/dev/null || true
  fi
}

# ============================================================
# 1. Sync manifests from S3
# ============================================================
sync_manifests() {
  log "Syncing manifests from s3://${MANIFEST_BUCKET}/${MANIFEST_PREFIX}"
  rm -rf "${MANIFEST_DIR}"
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
    --from-literal=POSTGRES_EXPORTER_URL="${database_url/postgresql+asyncpg:\/\//postgresql:\/\/}" \
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
    --from-literal=CELERY_WORKER_SEND_TASK_EVENTS="True" \
    --from-literal=CELERY_TASK_SEND_SENT_EVENT="True" \
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
    "${MANIFEST_DIR}/priorityclasses.yaml"
    "${MANIFEST_DIR}/storage/gp3-storageclass.yaml"
    "${MANIFEST_DIR}/config/configmap.yaml"
    "${MANIFEST_DIR}/pdb/api-pdb.yaml"
    "${MANIFEST_DIR}/pdb/rabbitmq-pdb.yaml"
    "${MANIFEST_DIR}/pdb/redis-pdb.yaml"
    "${MANIFEST_DIR}/redis/service.yaml"
    "${MANIFEST_DIR}/redis/deployment.yaml"
    "${MANIFEST_DIR}/rabbitmq/service.yaml"
    "${MANIFEST_DIR}/rabbitmq/statefulset.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-rbac.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-configmap.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-service.yaml"
    "${MANIFEST_DIR}/monitoring/alloy-deployment.yaml"
    "${MANIFEST_DIR}/monitoring/celery-exporter.yaml"
    "${MANIFEST_DIR}/monitoring/aws-node-termination-handler.yaml"
    "${MANIFEST_DIR}/autoscaling/cluster-autoscaler.yaml"
    "${MANIFEST_DIR}/api/service.yaml"
    "${MANIFEST_DIR}/api/deployment.yaml"
    "${MANIFEST_DIR}/api/hpa.yaml"
    "${MANIFEST_DIR}/workers/worker-standard.yaml"
    "${MANIFEST_DIR}/autoscaling/worker-standard-scaledobject.yaml"
    "${MANIFEST_DIR}/workers/worker-ml.yaml"
    "${MANIFEST_DIR}/workers/beat.yaml"
    "${MANIFEST_DIR}/ingress/ingress.yaml"
  )

  for file in "${ordered_files[@]}"; do
    if [[ -f "${file}" ]]; then
      apply_manifest_safely "${file}"
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
  kubectl -n "${NAMESPACE}" rollout status deployment/cluster-autoscaler --timeout=180s

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
  wait_for_apiserver 180
  refresh_ecr_pull_secret
  sync_runtime_config
  cleanup_stale_nodes
  cleanup_stale_terminating_pods
  label_nodes_by_role
  install_aws_ebs_csi
  apply_keda_metrics_rbac_prereqs
  install_keda
  tune_kube_system_control_plane_footprint
  wait_for_apiserver 180
  cleanup_deprecated_autoscalers
  apply_manifests
  wait_for_rollouts
  log "Cluster reconciliation complete"
}

main "$@"
