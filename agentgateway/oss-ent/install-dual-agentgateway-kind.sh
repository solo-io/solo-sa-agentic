#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap a local kind cluster with both OSS agentgateway and Solo Enterprise
# for agentgateway installed side by side, then route both gateways to an
# in-cluster OpenAI-compatible mock LLM.

CLUSTER_NAME="${CLUSTER_NAME:-agentgateway-dual}"
OSS_AGW_NAMESPACE="${OSS_AGW_NAMESPACE:-${AGW_NAMESPACE:-agentgateway-system}}"
ENT_AGW_NAMESPACE="${ENT_AGW_NAMESPACE:-agentgateway-enterprise-system}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${MANIFEST_DIR:-${SCRIPT_DIR}/manifests}"

KIND_VERSION="${KIND_VERSION:-v0.30.0}"
KIND_INSTALL_DIR="${KIND_INSTALL_DIR:-${HOME}/.local/bin}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"

OSS_AGENTGATEWAY_VERSION="${OSS_AGENTGATEWAY_VERSION:-v1.1.0}"
OSS_AGENTGATEWAY_CRDS_CHART="${OSS_AGENTGATEWAY_CRDS_CHART:-oci://cr.agentgateway.dev/charts/agentgateway-crds}"
OSS_AGENTGATEWAY_CHART="${OSS_AGENTGATEWAY_CHART:-oci://cr.agentgateway.dev/charts/agentgateway}"

INSTALL_OSS="${INSTALL_OSS:-true}"
INSTALL_ENTERPRISE="${INSTALL_ENTERPRISE:-true}"
ENT_AGENTGATEWAY_VERSION="${ENT_AGENTGATEWAY_VERSION:-v2026.5.0-beta.3}"
ENT_AGENTGATEWAY_CRDS_RELEASE="${ENT_AGENTGATEWAY_CRDS_RELEASE:-enterprise-agentgateway-crds}"
ENT_AGENTGATEWAY_CRDS_CHART="${ENT_AGENTGATEWAY_CRDS_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds}"
ENT_AGENTGATEWAY_CHART="${ENT_AGENTGATEWAY_CHART:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway}"

RUN_SMOKE_TESTS="${RUN_SMOKE_TESTS:-true}"
OSS_LOCAL_PORT="${OSS_LOCAL_PORT:-18080}"
ENT_LOCAL_PORT="${ENT_LOCAL_PORT:-18081}"

TMP_DIR="$(mktemp -d)"
PIDS=()

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
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

create_kind_cluster() {
  require_cmd docker
  require_cmd kind

  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    log "Using existing kind cluster ${CLUSTER_NAME}"
    kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
    return
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

install_oss_agentgateway() {
  if [[ "$INSTALL_OSS" != "true" ]]; then
    log "Skipping OSS agentgateway because INSTALL_OSS=${INSTALL_OSS}"
    return
  fi

  log "Installing OSS agentgateway ${OSS_AGENTGATEWAY_VERSION}"
  helm upgrade -i agentgateway-crds "$OSS_AGENTGATEWAY_CRDS_CHART" \
    --create-namespace \
    --namespace "$OSS_AGW_NAMESPACE" \
    --version "$OSS_AGENTGATEWAY_VERSION" \
    --set controller.image.pullPolicy=Always

  helm upgrade -i agentgateway "$OSS_AGENTGATEWAY_CHART" \
    --namespace "$OSS_AGW_NAMESPACE" \
    --version "$OSS_AGENTGATEWAY_VERSION" \
    --set controller.image.pullPolicy=Always \
    --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
    --wait \
    --timeout 10m

  kubectl -n "$OSS_AGW_NAMESPACE" rollout status deployment/agentgateway --timeout=5m
  kubectl get gatewayclass agentgateway >/dev/null
}

transfer_agentgateway_crd_ownership_to_enterprise() {
  if [[ "$INSTALL_ENTERPRISE" != "true" ]]; then
    return
  fi

  local crds
  crds="$(kubectl get crd \
    -o jsonpath='{range .items[?(@.spec.group=="agentgateway.dev")]}{.metadata.name}{"\n"}{end}')"

  if [[ -z "$crds" ]]; then
    log "No existing agentgateway.dev CRDs found to transfer"
    return
  fi

  log "Transferring agentgateway.dev CRD Helm ownership to ${ENT_AGENTGATEWAY_CRDS_RELEASE}"
  while IFS= read -r crd; do
    [[ -n "$crd" ]] || continue
    kubectl annotate crd "$crd" \
      "meta.helm.sh/release-name=${ENT_AGENTGATEWAY_CRDS_RELEASE}" \
      "meta.helm.sh/release-namespace=${ENT_AGW_NAMESPACE}" \
      --overwrite
    kubectl label crd "$crd" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite
  done <<< "$crds"
}

install_enterprise_agentgateway() {
  if [[ "$INSTALL_ENTERPRISE" != "true" ]]; then
    log "Skipping Enterprise agentgateway because INSTALL_ENTERPRISE=${INSTALL_ENTERPRISE}"
    return
  fi

  [[ -n "${AGENTGATEWAY_LICENSE_KEY:-}" ]] || die "set AGENTGATEWAY_LICENSE_KEY before installing Enterprise agentgateway"

  log "Installing Solo Enterprise for agentgateway ${ENT_AGENTGATEWAY_VERSION}"
  helm upgrade -i "$ENT_AGENTGATEWAY_CRDS_RELEASE" "$ENT_AGENTGATEWAY_CRDS_CHART" \
    --create-namespace \
    --namespace "$ENT_AGW_NAMESPACE" \
    --version "$ENT_AGENTGATEWAY_VERSION"

  helm upgrade -i enterprise-agentgateway "$ENT_AGENTGATEWAY_CHART" \
    --namespace "$ENT_AGW_NAMESPACE" \
    --version "$ENT_AGENTGATEWAY_VERSION" \
    --set controller.image.pullPolicy=Always \
    --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true \
    --set-string "licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}" \
    --wait \
    --timeout 10m

  kubectl -n "$ENT_AGW_NAMESPACE" rollout status deployment/enterprise-agentgateway --timeout=5m
  log "Verifying Enterprise GatewayClass from Enterprise controller chart"
  kubectl get gatewayclass enterprise-agentgateway >/dev/null || die "enterprise-agentgateway GatewayClass was not installed by enterprise-agentgateway"
}

ensure_namespace() {
  local namespace="$1"
  kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"
}

install_mock_llm_in_namespace() {
  local namespace="$1"
  log "Installing mock OpenAI-compatible LLM in ${namespace}"
  ensure_namespace "$namespace"
  kubectl -n "$namespace" apply -f "${MANIFEST_DIR}/mock-llm"
  kubectl -n "$namespace" rollout status deployment/mock-llm --timeout=3m
}

install_mock_llm() {
  if [[ "$INSTALL_OSS" == "true" ]]; then
    install_mock_llm_in_namespace "$OSS_AGW_NAMESPACE"
  fi

  if [[ "$INSTALL_ENTERPRISE" == "true" && "$ENT_AGW_NAMESPACE" != "$OSS_AGW_NAMESPACE" ]]; then
    install_mock_llm_in_namespace "$ENT_AGW_NAMESPACE"
  elif [[ "$INSTALL_ENTERPRISE" == "true" && "$INSTALL_OSS" != "true" ]]; then
    install_mock_llm_in_namespace "$ENT_AGW_NAMESPACE"
  fi
}

configure_routes() {
  log "Configuring OSS and Enterprise agentgateway routes to mock LLM"
  if [[ "$INSTALL_OSS" == "true" ]]; then
    kubectl -n "$OSS_AGW_NAMESPACE" apply -f "${MANIFEST_DIR}/oss"
    log "Waiting for OSS agentgateway Gateway to be Programmed"
    kubectl -n "$OSS_AGW_NAMESPACE" wait --for=condition=Programmed gateway/oss-agentgateway-proxy --timeout=5m
    log "Waiting for OSS agentgateway proxy deployment rollout"
    kubectl -n "$OSS_AGW_NAMESPACE" rollout status deployment/oss-agentgateway-proxy --timeout=5m
  fi

  if [[ "$INSTALL_ENTERPRISE" == "true" ]]; then
    kubectl get gatewayclass enterprise-agentgateway >/dev/null || die "enterprise-agentgateway GatewayClass is missing; the Enterprise controller chart must install it before applying Enterprise Gateway manifests"
    kubectl -n "$ENT_AGW_NAMESPACE" apply -f "${MANIFEST_DIR}/enterprise"
    log "Waiting for Enterprise agentgateway Gateway to be Programmed"
    kubectl -n "$ENT_AGW_NAMESPACE" wait --for=condition=Programmed gateway/enterprise-agentgateway-proxy --timeout=5m
    log "Waiting for Enterprise agentgateway proxy deployment rollout"
    kubectl -n "$ENT_AGW_NAMESPACE" rollout status deployment/enterprise-agentgateway-proxy --timeout=5m
  fi
}

wait_for_port_forward() {
  local log_file="$1"
  local pid="$2"
  local deadline=$((SECONDS + 30))
  until grep -q "Forwarding from" "$log_file" 2>/dev/null; do
    kill -0 "$pid" >/dev/null 2>&1 || return 1
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 1
  done
}

smoke_test_gateway() {
  local name="$1"
  local namespace="$2"
  local service="$3"
  local port="$4"
  local out="${TMP_DIR}/${name}.json"
  local log_file="${TMP_DIR}/${name}-port-forward.log"

  log "Smoke testing ${name} on http://127.0.0.1:${port}"
  kubectl -n "$namespace" port-forward "service/${service}" "${port}:80" >"$log_file" 2>&1 &
  local pf_pid="$!"
  PIDS+=("$pf_pid")

  wait_for_port_forward "$log_file" "$pf_pid" || {
    cat "$log_file" >&2 || true
    die "port-forward for ${name} did not become ready"
  }

  curl -fsS "http://127.0.0.1:${port}/v1/chat/completions" \
    -H "content-type: application/json" \
    -H "authorization: Bearer local-dev" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello from '"${name}"'"}]}' \
    -o "$out"

  printf '%s response: ' "$name"
  tr -d '\n' < "$out"
  printf '\n'
}

smoke_tests() {
  if [[ "$RUN_SMOKE_TESTS" != "true" ]]; then
    log "Skipping smoke tests because RUN_SMOKE_TESTS=${RUN_SMOKE_TESTS}"
    return
  fi

  require_cmd curl
  if [[ "$INSTALL_OSS" == "true" ]]; then
    smoke_test_gateway "oss" "$OSS_AGW_NAMESPACE" "oss-agentgateway-proxy" "$OSS_LOCAL_PORT"
  fi

  if [[ "$INSTALL_ENTERPRISE" == "true" ]]; then
    smoke_test_gateway "enterprise" "$ENT_AGW_NAMESPACE" "enterprise-agentgateway-proxy" "$ENT_LOCAL_PORT"
  fi
}

print_summary() {
  log "Installed resources"
  if [[ "$INSTALL_OSS" == "true" ]]; then
    kubectl -n "$OSS_AGW_NAMESPACE" get pods,svc,gateway,httproute,agentgatewaybackend
  fi
  if [[ "$INSTALL_ENTERPRISE" == "true" ]]; then
    kubectl -n "$ENT_AGW_NAMESPACE" get pods,svc,gateway,httproute,agentgatewaybackend
  fi
  kubectl get gatewayclass

  cat <<EOF

Done.

Useful commands:
EOF

  if [[ "$INSTALL_OSS" == "true" ]]; then
    cat <<EOF
  kubectl -n ${OSS_AGW_NAMESPACE} port-forward service/oss-agentgateway-proxy ${OSS_LOCAL_PORT}:80
  curl http://127.0.0.1:${OSS_LOCAL_PORT}/v1/chat/completions -H 'content-type: application/json' -H 'authorization: Bearer local-dev' -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello oss"}]}'
EOF
  fi

  if [[ "$INSTALL_ENTERPRISE" == "true" ]]; then
    cat <<EOF
  kubectl -n ${ENT_AGW_NAMESPACE} port-forward service/enterprise-agentgateway-proxy ${ENT_LOCAL_PORT}:80
  curl http://127.0.0.1:${ENT_LOCAL_PORT}/v1/chat/completions -H 'content-type: application/json' -H 'authorization: Bearer local-dev' -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello enterprise"}]}'
EOF
  fi
}

main() {
  require_cmd kubectl
  require_cmd helm
  install_kind_if_missing
  create_kind_cluster
  install_gateway_api_crds
  install_oss_agentgateway
  transfer_agentgateway_crd_ownership_to_enterprise
  install_enterprise_agentgateway
  install_mock_llm
  configure_routes
  smoke_tests
  print_summary
}

main "$@"
