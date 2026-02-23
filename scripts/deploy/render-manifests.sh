#!/usr/bin/env bash
set -euo pipefail

: "${API_IMAGE:?API_IMAGE is required}"
: "${WORKER_IMAGE:?WORKER_IMAGE is required}"
: "${ALLOWED_INGRESS_CIDRS:?ALLOWED_INGRESS_CIDRS is required}"
: "${ALB_SECURITY_GROUP_ID:?ALB_SECURITY_GROUP_ID is required}"

OUT_DIR="${1:-build/manifests}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
cp -R k8s/. "${OUT_DIR}/"

while IFS= read -r -d '' file; do
  sed -i \
    -e "s|__API_IMAGE__|${API_IMAGE}|g" \
    -e "s|__WORKER_IMAGE__|${WORKER_IMAGE}|g" \
    -e "s|__ALLOWED_INGRESS_CIDRS__|${ALLOWED_INGRESS_CIDRS}|g" \
    -e "s|__ALB_SECURITY_GROUP_ID__|${ALB_SECURITY_GROUP_ID}|g" \
    "${file}"
done < <(find "${OUT_DIR}" -type f -name "*.yaml" -print0)

echo "Rendered manifests into ${OUT_DIR}"

