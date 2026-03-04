#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-pixtools}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
PVC_NAME="${PVC_NAME:-rabbitmq-data-rabbitmq-0}"
STATEFULSET_NAME="${STATEFULSET_NAME:-rabbitmq}"
TARGET_STORAGE_CLASS="${TARGET_STORAGE_CLASS:-gp3}"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

wait_for_condition() {
  local description="$1"
  shift
  local timeout_seconds="${1:-180}"
  shift
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if "$@"; then
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  log "Timed out waiting for ${description}"
  return 1
}

current_storage_class() {
  kubectl -n "${NAMESPACE}" get pvc "${PVC_NAME}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true
}

log "Starting RabbitMQ PVC migration to StorageClass ${TARGET_STORAGE_CLASS}"

if ! kubectl get storageclass "${TARGET_STORAGE_CLASS}" >/dev/null 2>&1; then
  log "Required StorageClass ${TARGET_STORAGE_CLASS} does not exist"
  exit 1
fi

existing_sc="$(current_storage_class)"
if [[ "${existing_sc}" == "${TARGET_STORAGE_CLASS}" ]]; then
  log "RabbitMQ PVC already uses ${TARGET_STORAGE_CLASS}; nothing to do"
  exit 0
fi

if [[ -n "${existing_sc}" ]]; then
  log "Current RabbitMQ PVC storage class: ${existing_sc}"
else
  log "RabbitMQ PVC does not exist yet; scaling StatefulSet up and waiting for bind"
fi

log "Scaling StatefulSet/${STATEFULSET_NAME} to 0 for migration"
kubectl -n "${NAMESPACE}" scale statefulset "${STATEFULSET_NAME}" --replicas=0 >/dev/null
wait_for_condition "RabbitMQ pod termination" 180 \
  bash -lc "! kubectl -n '${NAMESPACE}' get pod ${STATEFULSET_NAME}-0 >/dev/null 2>&1"

if kubectl -n "${NAMESPACE}" get pvc "${PVC_NAME}" >/dev/null 2>&1; then
  released_pv="$(kubectl -n "${NAMESPACE}" get pvc "${PVC_NAME}" -o jsonpath='{.spec.volumeName}')"
  log "Deleting PVC ${PVC_NAME}"
  kubectl -n "${NAMESPACE}" delete pvc "${PVC_NAME}" >/dev/null

  if [[ -n "${released_pv}" ]]; then
    log "Deleting released PV ${released_pv}"
    kubectl delete pv "${released_pv}" >/dev/null 2>&1 || true
  fi
fi

log "Scaling StatefulSet/${STATEFULSET_NAME} back to 1"
kubectl -n "${NAMESPACE}" scale statefulset "${STATEFULSET_NAME}" --replicas=1 >/dev/null

wait_for_condition "RabbitMQ PVC bind" 180 \
  bash -lc "[[ \"\$(kubectl -n '${NAMESPACE}' get pvc '${PVC_NAME}' -o jsonpath='{.status.phase}' 2>/dev/null)\" == 'Bound' ]]"

wait_for_condition "RabbitMQ pod readiness" 300 \
  bash -lc "[[ \"\$(kubectl -n '${NAMESPACE}' get pod '${STATEFULSET_NAME}-0' -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)\" == 'true' ]]"

new_sc="$(current_storage_class)"
if [[ "${new_sc}" != "${TARGET_STORAGE_CLASS}" ]]; then
  log "RabbitMQ PVC rebound, but storage class is ${new_sc:-<empty>} instead of ${TARGET_STORAGE_CLASS}"
  exit 1
fi

log "RabbitMQ PVC migration complete"
