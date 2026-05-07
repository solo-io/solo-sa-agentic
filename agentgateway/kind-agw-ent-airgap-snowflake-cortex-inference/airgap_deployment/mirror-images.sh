#!/usr/bin/env zsh
set -euo pipefail

# Mirror Enterprise AgentGateway images to a private registry.
# All registry/version config is read from env.sh — no hardcoded values here.
#
# Prerequisites:
#   docker login ${HARBOR_REGISTRY}
#   oras (https://oras.land) — copies images WITH cosign signatures (OCI referrers)
#
# Usage:
#   ./mirror-images.sh              # mirrors the version from env.sh
#   ./mirror-images.sh 2.3.3        # mirrors only 2.3.3
#   ./mirror-images.sh 2026.5.0-beta.2  # mirrors only beta

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../env.sh"

# --- Source registries ---
SOLO_REGISTRY="us-docker.pkg.dev/solo-public/enterprise-agentgateway"
GLOO_MESH_REGISTRY="gcr.io/gloo-mesh"

# --- AGW versions ---
AGW_VERSIONS=("${AGW_VERSION}")
if [[ $# -ge 1 ]]; then
  AGW_VERSIONS=("$1")
fi

mirror_image() {
  local src="$1"
  local dst="$2"
  echo "  COPY  $src → $dst"
  oras cp --recursive "$src" "$dst"
  echo "  OK    $dst"
}

echo "=== Mirroring AGW Enterprise images to ${HARBOR_REGISTRY}/${HARBOR_PROJECT} ==="
echo ""

for VERSION in "${AGW_VERSIONS[@]}"; do
  echo "--- AGW version: ${VERSION} ---"

  # Controller
  mirror_image \
    "${SOLO_REGISTRY}/enterprise-agentgateway-controller:${VERSION}" \
    "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/enterprise-agentgateway-controller:${VERSION}"

  # Proxy (data plane)
  mirror_image \
    "${SOLO_REGISTRY}/agentgateway-enterprise:${VERSION}" \
    "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/agentgateway-enterprise:${VERSION}"

  echo ""
done

echo "--- Shared sidecar images ---"

# ExtAuth
mirror_image \
  "${GLOO_MESH_REGISTRY}/ext-auth-service:${EXTAUTH_VERSION}" \
  "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/ext-auth-service:${EXTAUTH_VERSION}"

# Rate Limiter
mirror_image \
  "${GLOO_MESH_REGISTRY}/rate-limiter:${RATELIMITER_VERSION}" \
  "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/rate-limiter:${RATELIMITER_VERSION}"

# Redis (ext-cache)
mirror_image \
  "docker.io/library/redis:${REDIS_VERSION}" \
  "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis:${REDIS_VERSION}"

echo ""
echo "=== Mirroring Helm charts ==="

mkdir -p /tmp/agw-charts

for VERSION in "${AGW_VERSIONS[@]}"; do
  echo "--- Helm charts for ${VERSION} ---"

  CHART_VERSION="v${VERSION}"

  echo "  PULL  enterprise-agentgateway-crds:${CHART_VERSION}"
  helm pull "oci://${SOLO_REGISTRY}/charts/enterprise-agentgateway-crds" --version "${CHART_VERSION}" \
    --destination /tmp/agw-charts/ 2>/dev/null || true

  echo "  PULL  enterprise-agentgateway:${CHART_VERSION}"
  helm pull "oci://${SOLO_REGISTRY}/charts/enterprise-agentgateway" --version "${CHART_VERSION}" \
    --destination /tmp/agw-charts/ 2>/dev/null || true

  for CHART_TGZ in /tmp/agw-charts/enterprise-agentgateway*${VERSION}*.tgz(N); do
    if [[ -f "$CHART_TGZ" ]]; then
      echo "  PUSH  $(basename $CHART_TGZ) → oci://${HARBOR_REGISTRY}/${HARBOR_PROJECT}/charts"
      helm push "$CHART_TGZ" "oci://${HARBOR_REGISTRY}/${HARBOR_PROJECT}/charts" 2>/dev/null || \
        echo "  WARN  Failed to push $(basename $CHART_TGZ) — push manually if needed"
    fi
  done
done

rm -rf /tmp/agw-charts/

echo ""
echo "=== Done ==="
echo ""
echo "Image summary:"
for VERSION in "${AGW_VERSIONS[@]}"; do
  echo "  ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/enterprise-agentgateway-controller:${VERSION}"
  echo "  ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/agentgateway-enterprise:${VERSION}"
done
echo "  ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/ext-auth-service:${EXTAUTH_VERSION}"
echo "  ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/rate-limiter:${RATELIMITER_VERSION}"
echo "  ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis:${REDIS_VERSION}"
