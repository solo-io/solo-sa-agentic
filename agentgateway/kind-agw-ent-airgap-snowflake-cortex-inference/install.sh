#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

LICENSE_KEY="${AGENTGATEWAY_LICENSE_KEY:-${AGENTGATEWAY_LICENSE:?Set AGENTGATEWAY_LICENSE_KEY or AGENTGATEWAY_LICENSE env var}}"
HELM_VERSION="v${AGW_VERSION#v}"

echo "==> Installing Gateway API CRDs"
kubectl --context "${CONTEXT}" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

echo "==> Creating namespace ${AGW_NAMESPACE}"
kubectl --context "${CONTEXT}" create namespace "${AGW_NAMESPACE}" --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f -

echo "==> Installing Enterprise AgentGateway CRDs ${HELM_VERSION}"
helm --kube-context "${CONTEXT}" upgrade -i --create-namespace -n "${AGW_NAMESPACE}" --version "${HELM_VERSION}" \
  enterprise-agentgateway-crds \
  "${AGW_HELM_REGISTRY}/enterprise-agentgateway-crds"

echo "==> Creating EnterpriseAgentgatewayParameters (Harbor images)..."
kubectl --context "${CONTEXT}" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: shared-ent-agentgateway-parameters
  namespace: ${AGW_NAMESPACE}
spec:
  # To pull from a private registry, create a docker-registry secret and uncomment:
  # deployment:
  #   spec:
  #     template:
  #       spec:
  #         imagePullSecrets:
  #           - name: harbor-registry-secret
  image:
    pullPolicy: IfNotPresent
    registry: ${HARBOR_REGISTRY}
    repository: ${HARBOR_PROJECT}/agentgateway-enterprise
    tag: "${AGW_VERSION}"
  sharedExtensions:
    extCache:
      enabled: true
      image:
        pullPolicy: IfNotPresent
        registry: ${HARBOR_REGISTRY}
        repository: ${HARBOR_PROJECT}/redis
        tag: "${REDIS_VERSION}"
    extauth:
      enabled: true
      image:
        pullPolicy: IfNotPresent
        registry: ${HARBOR_REGISTRY}
        repository: ${HARBOR_PROJECT}/ext-auth-service
        tag: "${EXTAUTH_VERSION}"
    ratelimiter:
      enabled: true
      image:
        pullPolicy: IfNotPresent
        registry: ${HARBOR_REGISTRY}
        repository: ${HARBOR_PROJECT}/rate-limiter
        tag: "${RATELIMITER_VERSION}"
EOF

echo "==> Generating AGW Helm values..."
AGW_VALUES="${SCRIPT_DIR}/agw-values.yaml"
envsubst < "${SCRIPT_DIR}/agw-values.yaml.tpl" > "${AGW_VALUES}"

echo "==> Installing Enterprise AgentGateway ${HELM_VERSION}"
helm --kube-context "${CONTEXT}" upgrade -i -n "${AGW_NAMESPACE}" --version "${HELM_VERSION}" \
  enterprise-agentgateway \
  "${AGW_HELM_REGISTRY}/enterprise-agentgateway" \
  --set-string licensing.licenseKey="${LICENSE_KEY}" \
  --set image.registry="${HARBOR_REGISTRY}/${HARBOR_PROJECT}" \
  --set image.tag="${AGW_VERSION}" \
  --set image.pullPolicy=IfNotPresent \
  --set gatewayClassParametersRefs.enterprise-agentgateway.group=enterpriseagentgateway.solo.io \
  --set gatewayClassParametersRefs.enterprise-agentgateway.kind=EnterpriseAgentgatewayParameters \
  --set gatewayClassParametersRefs.enterprise-agentgateway.name=shared-ent-agentgateway-parameters \
  --set gatewayClassParametersRefs.enterprise-agentgateway.namespace="${AGW_NAMESPACE}" \
  -f "${AGW_VALUES}"

rm -f "${AGW_VALUES}"

echo "==> Waiting for enterprise-agentgateway deployment..."
kubectl --context "${CONTEXT}" -n "${AGW_NAMESPACE}" rollout status deploy/enterprise-agentgateway --timeout=120s

echo "==> AGW ${HELM_VERSION} installed successfully"
kubectl --context "${CONTEXT}" -n "${AGW_NAMESPACE}" get pods
