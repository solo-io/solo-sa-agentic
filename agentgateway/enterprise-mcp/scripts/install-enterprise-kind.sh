#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-enterprise-mcp-agentgateway}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KIND_VERSION="${KIND_VERSION:-v0.30.0}"
KIND_INSTALL_DIR="${KIND_INSTALL_DIR:-${HOME}/.local/bin}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"
ENT_AGENTGATEWAY_VERSION="${ENT_AGENTGATEWAY_VERSION:-v2026.5.0-beta.3}"
ENT_AGENTGATEWAY_CRDS_RELEASE="${ENT_AGENTGATEWAY_CRDS_RELEASE:-enterprise-agentgateway-crds}"
ENT_AGENTGATEWAY_CRDS_CHART="${ENT_AGENTGATEWAY_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds}"
ENT_AGENTGATEWAY_RELEASE="${ENT_AGENTGATEWAY_RELEASE:-enterprise-agentgateway}"
ENT_AGENTGATEWAY_CHART="${ENT_AGENTGATEWAY_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway}"
CLEAN_INSTALL="${CLEAN_INSTALL:-true}"
LOCAL_PORT="${LOCAL_PORT:-18082}"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_license() {
  [[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || die "set AGENTGATEWAY_LICENSE_KEY before installing Enterprise agentgateway"
}

install_kind_if_missing() {
  if command -v kind >/dev/null 2>&1; then
    return
  fi

  require_cmd curl

  local os arch url target
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) die "unsupported OS for kind install: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "unsupported architecture for kind install: $(uname -m)" ;;
  esac

  mkdir -p "$KIND_INSTALL_DIR"
  target="${KIND_INSTALL_DIR}/kind"
  url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"

  log "Installing kind ${KIND_VERSION} to ${target}"
  curl -fsSL "$url" -o "$target"
  chmod +x "$target"
  export PATH="${KIND_INSTALL_DIR}:${PATH}"
}

create_cluster() {
  require_cmd docker
  install_kind_if_missing

  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    if [[ "$CLEAN_INSTALL" == "true" ]]; then
      log "Deleting existing kind cluster ${CLUSTER_NAME} for clean install"
      kind delete cluster --name "$CLUSTER_NAME"
    else
      log "Using existing kind cluster ${CLUSTER_NAME}"
      kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
      return
    fi
  fi

  log "Creating kind cluster ${CLUSTER_NAME}"
  if [[ -n "$KIND_NODE_IMAGE" ]]; then
    kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --wait 5m
  else
    kind create cluster --name "$CLUSTER_NAME" --wait 5m
  fi
}

install_gateway_api_crds() {
  log "Installing Kubernetes Gateway API CRDs ${GATEWAY_API_VERSION}"
  kubectl apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

  kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=2m
  kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=2m
  kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=2m
}

install_enterprise_agentgateway() {
  log "Installing Solo Enterprise for agentgateway ${ENT_AGENTGATEWAY_VERSION}"
  helm upgrade -i "$ENT_AGENTGATEWAY_CRDS_RELEASE" "$ENT_AGENTGATEWAY_CRDS_CHART" \
    --create-namespace \
    --namespace "$AGW_NAMESPACE" \
    --version "$ENT_AGENTGATEWAY_VERSION"

  helm upgrade -i "$ENT_AGENTGATEWAY_RELEASE" "$ENT_AGENTGATEWAY_CHART" \
    --namespace "$AGW_NAMESPACE" \
    --version "$ENT_AGENTGATEWAY_VERSION" \
    --set controller.image.pullPolicy=Always \
    --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
    --set-string "licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}" \
    --wait \
    --timeout 10m

  kubectl -n "$AGW_NAMESPACE" rollout status deployment/enterprise-agentgateway --timeout=5m
  kubectl get gatewayclass enterprise-agentgateway >/dev/null
}

install_enterprise_mcp_examples() {
  log "Deploying enterprise MCP mock LLM and examples"
  kubectl apply -f "${ROOT_DIR}/manifests/kubernetes/00-namespace.yaml"
  kubectl -n "$AGW_NAMESPACE" apply -f "${ROOT_DIR}/manifests/mock-llm"
  kubectl -n "$AGW_NAMESPACE" apply -f "${ROOT_DIR}/manifests/mock-mcp-core-banking"
  kubectl -n "$AGW_NAMESPACE" apply -f "${ROOT_DIR}/manifests/mock-vendor-case-management"
  kubectl -n "$AGW_NAMESPACE" apply -f "${ROOT_DIR}/manifests/mock-idp"
  kubectl -n "$AGW_NAMESPACE" apply -f "${ROOT_DIR}/manifests/mock-agent-coordination"
  kubectl -n "$AGW_NAMESPACE" rollout status deployment/mock-llm --timeout=3m
  kubectl -n "$AGW_NAMESPACE" rollout status deployment/core-banking-mcp --timeout=3m
  kubectl -n "$AGW_NAMESPACE" rollout status deployment/vendor-case-management-mcp --timeout=3m
  kubectl -n "$AGW_NAMESPACE" rollout status deployment/enterprise-idp --timeout=3m
  kubectl -n "$AGW_NAMESPACE" rollout status deployment/agent-coordination-service --timeout=3m

  kubectl apply -f "${ROOT_DIR}/manifests/kubernetes/10-mcp-gateway.yaml"
  kubectl apply -f "${ROOT_DIR}/manifests/kubernetes/20-mcp-backends-and-routes.yaml"
  kubectl apply -f "${ROOT_DIR}/manifests/kubernetes/30-identity-and-tool-policy.yaml"
  kubectl apply -f "${ROOT_DIR}/manifests/kubernetes/40-runtime-guardrails.yaml"
  kubectl apply -f "${ROOT_DIR}/manifests/kubernetes/60-a2a-system-support.yaml"

  log "Skipping placeholder observability manifest by default"
  log "Review 50 before applying to a real OTEL collector"
}

main() {
  require_cmd kubectl
  require_cmd helm
  require_cmd curl
  require_license

  create_cluster
  install_gateway_api_crds
  install_enterprise_agentgateway
  install_enterprise_mcp_examples

  log "Enterprise MCP agentgateway kind install completed"
  log "Run 'make status' and follow the README curl steps to test each use case"
}

main "$@"
