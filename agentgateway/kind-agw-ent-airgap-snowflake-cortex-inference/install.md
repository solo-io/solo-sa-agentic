# AgentGateway Enterprise — Full Install Guide

End-to-end setup: Kind cluster with private registry, AGW Enterprise from Harbor, Snowflake Cortex backend, Keycloak JWT auth with chatbot demo, and Inference Extension with vLLM.

All configuration is centralized in `env.sh` — update it before running any scripts.

## Prerequisites

- Docker running with Kind installed
- `helm`, `kubectl`, `oras` CLIs
- Harbor (or any OCI-compatible registry) accessible from the host
- Harbor CA cert at the path set in `HARBOR_CA_CERT` (for self-signed certs)
- `AGENTGATEWAY_LICENSE_KEY` env var set
- Keycloak container running (named `keycloak`, accessible at `${KEYCLOAK_URL}`)
- Snowflake account with a Programmatic Access Token (for the Cortex backend)

## Directory Layout

```
03_project/
├── env.sh                      # Central configuration (registry, versions, certs)
├── install.md                  # This file
├── kind-config.yaml            # Kind cluster config (1 control-plane + 1 worker)
├── create-cluster.sh           # Creates Kind cluster + configures Harbor on nodes
├── install.sh                  # Installs Gateway API CRDs + AGW Enterprise from Harbor
├── agw-values.yaml.tpl         # Helm values template (envsubst'd by install.sh)
├── airgap_deployment/
│   ├── README.md               # Air-gap image inventory + instructions
│   └── mirror-images.sh        # Mirror images + helm charts to private registry
├── snowflake_cortex/
│   ├── README.md               # Snowflake Cortex backend setup details
│   └── snowflake-cortex.yaml   # Backend, Gateway, HTTPRoute for Cortex
├── keycloak/
│   ├── keycloak-setup.md       # Keycloak OIDC integration details
│   ├── keycloak-svc.yaml       # K8s Service + Endpoints for in-cluster Keycloak access
│   ├── jwt-auth-policy.yaml    # EnterpriseAgentgatewayPolicy (JWT validation)
│   └── chatbot/
│       ├── app.py              # Streamlit chatbot with Keycloak login + auth flow UI
│       ├── Dockerfile          # Python 3.12 slim + streamlit + requests
│       └── deploy.yaml         # Deployment + LoadBalancer Service
└── inference_extension/
    ├── README.md               # Inference Extension setup details
    ├── inference-gateway.yaml  # Gateway + HTTPRoute for InferencePool
    └── vllm-qwen.yaml          # vLLM CPU deployment (Qwen2.5-1.5B-Instruct)
```

---

## Phase 1: Kind Cluster + Private Registry

### 1.1 Configure Environment

Review and update `env.sh` with your registry, versions, and cert paths:

```bash
cat env.sh
```

Key variables:
- `CLUSTER_NAME` — Kind cluster name (default: `agw-sq-example`)
- `AGW_VERSION` — AgentGateway version (default: `2.3.3`)
- `HARBOR_REGISTRY` / `HARBOR_PROJECT` — private registry coordinates
- `HARBOR_CA_CERT` — path to the registry CA cert (for self-signed)

### 1.2 Mirror Images to Private Registry

Before creating the cluster, mirror all required images to your private registry.

```bash
source env.sh

# Login to registries
docker login ${HARBOR_REGISTRY}
helm registry login ${HARBOR_REGISTRY}

# Mirror all images + helm charts
cd airgap_deployment
./mirror-images.sh
cd ..
```

See `airgap_deployment/README.md` for the full image inventory and manual fallback steps.

### 1.3 Create Kind Cluster

```bash
./create-cluster.sh
```

This script:
1. Creates a Kind cluster with 1 control-plane + 1 worker node (`kind-config.yaml`)
2. Adds `/etc/hosts` entry on each node so `${HARBOR_REGISTRY}` resolves to the Docker bridge IP
3. Copies the Harbor CA cert into containerd's cert store on each node
4. Restarts containerd so nodes can pull from the private registry

Verify the cluster is ready:

```bash
source env.sh
kubectl --context ${CONTEXT} get nodes
```

---

## Phase 2: Install AgentGateway Enterprise

### 2.1 Install AGW from Private Registry

```bash
./install.sh
```

This script:
1. Installs Gateway API CRDs (v1.5.0)
2. Creates the `${AGW_NAMESPACE}` namespace
3. Installs AGW Enterprise CRDs from `${AGW_HELM_REGISTRY}`
4. Creates an `EnterpriseAgentgatewayParameters` resource pointing all images (proxy, ext-auth, rate-limiter, redis) to `${HARBOR_REGISTRY}/${HARBOR_PROJECT}`
5. Generates Helm values from `agw-values.yaml.tpl` via `envsubst`
6. Installs AGW Enterprise with the license key and Harbor image overrides

Verify:

```bash
source env.sh
kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} get pods
kubectl --context ${CONTEXT} get gatewayclass
```

Expected: `enterprise-agentgateway` controller pod running, `enterprise-agentgateway` GatewayClass accepted.

---

## Phase 3: Snowflake Cortex Backend

### 3.1 Create the Snowflake PAT Secret

Generate a Programmatic Access Token in the Snowflake UI (Settings > Programmatic Access Tokens), then:

```bash
source env.sh
kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} create secret generic snowflake-cortex-api-key \
  --from-literal=Authorization="Bearer ${SNOWFLAKE_PAT}" \
  --dry-run=client -o yaml | kubectl --context ${CONTEXT} apply -f -
```

### 3.2 Deploy Snowflake Cortex Backend + Gateway

```bash
source env.sh
kubectl --context ${CONTEXT} apply -f snowflake_cortex/snowflake-cortex.yaml
```

This creates:
- `AgentgatewayBackend/snowflake-cortex-backend` — OpenAI-compatible provider pointing to Cortex with custom `pathPrefix` and `X-Snowflake-Authorization-Token-Type` header
- `Gateway/snowflake-cortex-gw` — HTTP listener on port 8080
- `HTTPRoute/snowflake-cortex-route` — routes all requests to the Cortex backend

**Note**: The YAML contains a placeholder PAT in the Secret. Step 3.1 overwrites it with the real token. Always run 3.1 first or re-run it after applying the YAML.

### 3.3 Test (without auth)

```bash
source env.sh
kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} port-forward svc/snowflake-cortex-gw 8080:8080 &

curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-large2",
    "messages": [{"role": "user", "content": "What is Snowflake Cortex?"}],
    "max_completion_tokens": 100
  }' | jq .

kill %1
```

See `snowflake_cortex/README.md` for Snowflake prerequisites (network policy, account URL format) and troubleshooting.

---

## Phase 4: Keycloak JWT Authentication + Chatbot (Optional)

> **Note**: Steps 4.1–4.3 set up Keycloak connectivity and the chatbot demo. If you already have an IdP configured, skip to **Step 4.4** to apply the JWT auth policy — this is required to enforce client authentication on the gateway.
>
> The chatbot demonstrates the full OIDC auth flow end-to-end:
>
> ```
> User (browser)
>   │
>   │  1. username/password
>   ▼
> Chatbot App (Streamlit) ──── 2. POST /token (password grant) ────► Keycloak
>   │                          ◄──── JWT (access_token, 5min TTL) ────┘
>   │
>   │  3. Bearer <JWT>
>   ▼
> AgentGateway ──── 4. GET /certs (JWKS) ────► Keycloak
>   │               validates JWT signature,
>   │               checks issuer claim
>   │
>   │  5. Forward request + Snowflake PAT
>   ▼
> LLM Backend (Snowflake Cortex / vLLM)
> ```
>
> - **Step 1–2**: User logs in via the chatbot UI. The chatbot sends credentials to Keycloak's token endpoint using the OIDC password grant. Keycloak validates and returns a signed JWT.
> - **Step 3**: Each chat message is sent to AGW with `Authorization: Bearer <JWT>`.
> - **Step 4**: AGW fetches Keycloak's public keys (JWKS) and validates the JWT signature and `iss` claim. No ext-auth service needed — validation happens natively in the AGW proxy.
> - **Step 5**: If valid, AGW forwards the request to the LLM backend, injecting the provider's auth (e.g., Snowflake PAT).

### 4.1 Connect Keycloak to Kind Network

The Keycloak container must be reachable from inside the Kind cluster:

```bash
docker network connect kind keycloak

# Get Keycloak's IP on the kind network
KEYCLOAK_KIND_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks.kind).IPAddress}}' keycloak)
echo "Keycloak kind-network IP: ${KEYCLOAK_KIND_IP}"
```

### 4.2 Create K8s Service for Keycloak

Update the Keycloak IP in the Endpoints resource, then apply:

```bash
source env.sh
KEYCLOAK_KIND_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks.kind).IPAddress}}' keycloak)

kubectl --context ${CONTEXT} apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${AGW_NAMESPACE}
spec:
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: keycloak
  namespace: ${AGW_NAMESPACE}
subsets:
  - addresses:
      - ip: ${KEYCLOAK_KIND_IP}
    ports:
      - port: 8080
        protocol: TCP
EOF
```

Verify from inside the cluster:

```bash
kubectl --context ${CONTEXT} run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}" http://keycloak.${AGW_NAMESPACE}.svc:8080/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration
# Expected: 200
```

### 4.3 Configure Keycloak Realm

Ensure the Keycloak realm has:

1. **Realm `frontendUrl` set** — so all JWTs have a consistent `iss` claim regardless of which URL is used to obtain the token. Set this to the externally reachable Keycloak URL (e.g., `${KEYCLOAK_URL}`).

2. **A public client for the chatbot** — create a client named `chatbot-ui` with:
   - `publicClient: true` (no client secret needed)
   - `directAccessGrantsEnabled: true` (enables password grant for the Streamlit login form)
   - `standardFlowEnabled: false` (auth code redirect doesn't work in Streamlit)

3. **A test user** — create a user with username/password for testing the chatbot login.

See `keycloak/keycloak-setup.md` for full Keycloak setup details including API commands.

### 4.4 Apply JWT Auth Policy

```bash
source env.sh
kubectl --context ${CONTEXT} apply -f keycloak/jwt-auth-policy.yaml
```

Verify the policy is accepted and attached:

```bash
kubectl --context ${CONTEXT} get eagpol jwt-auth-policy -n ${AGW_NAMESPACE} -o jsonpath='{.status}' | jq .
```

**Important**: The `issuer` field in `jwt-auth-policy.yaml` must match the `iss` claim in the JWT exactly. If Keycloak's `frontendUrl` is set, this should be `${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}`.

### 4.5 Test JWT Auth

```bash
source env.sh
kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} port-forward svc/snowflake-cortex-gw 8087:8080 &

# No token → 401
curl -s -w "\nHTTP %{http_code}\n" http://localhost:8087/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"snowflake-arctic","messages":[{"role":"user","content":"hi"}]}'
# Expected: 401 — authentication failure: no bearer token found

# Valid token → forwarded to backend
TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=chatbot-ui&username=testuser&password=testpassword" | jq -r '.access_token')

curl -s -w "\nHTTP %{http_code}\n" http://localhost:8087/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{"model":"snowflake-arctic","messages":[{"role":"user","content":"hi"}]}'
# Expected: JWT accepted, request forwarded to Snowflake

kill %1
```

### 4.6 Deploy Chatbot (Optional)

Build the chatbot image and load it into Kind:

```bash
source env.sh
cd keycloak/chatbot

docker build -t chatbot:latest .
kind load docker-image chatbot:latest --name ${CLUSTER_NAME}

kubectl --context ${CONTEXT} apply -f deploy.yaml
kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} rollout status deploy/chatbot --timeout=60s
cd ../..
```

Get the chatbot URL:

```bash
CHATBOT_IP=$(kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} get svc chatbot -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Chatbot URL: http://${CHATBOT_IP}:8501"
```

The chatbot shows the full auth flow in the UI:
1. User logs in with Keycloak credentials (password grant)
2. Keycloak returns a signed JWT
3. Each chat message includes `Authorization: Bearer <JWT>` to AGW
4. AGW validates the JWT via Keycloak JWKS
5. If valid, AGW forwards to the LLM backend

Check pod logs for auth flow details:

```bash
kubectl --context ${CONTEXT} -n ${AGW_NAMESPACE} logs -l app=chatbot -f
```

**Note**: Update `deploy.yaml` env vars if your Keycloak realm, client ID, model, or AGW gateway name differ from the defaults.

---

## Phase 5: Inference Extension (vLLM)

### 5.1 Enable Inference Extension in AGW

```bash
source env.sh
helm --kube-context ${CONTEXT} upgrade -i -n ${AGW_NAMESPACE} --version "v${AGW_VERSION}" \
  enterprise-agentgateway \
  "${AGW_HELM_REGISTRY}/enterprise-agentgateway" \
  --set inferenceExtension.enabled=true \
  --reuse-values
```

### 5.2 Deploy vLLM (CPU mode for local testing)

```bash
source env.sh
kubectl --context ${CONTEXT} apply -f inference_extension/vllm-qwen.yaml
```

This deploys vLLM serving Qwen2.5-1.5B-Instruct in CPU mode. Requires 11 CPU cores and 10Gi memory on the worker node. Wait 2-3 minutes for the model to download:

```bash
kubectl --context ${CONTEXT} get pods -l app=vllm-qwen25-15b-instruct -w
```

### 5.3 Install Inference Extension CRDs

```bash
source env.sh
kubectl --context ${CONTEXT} apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.1.0/manifests.yaml
```

### 5.4 Deploy InferencePool + EPP

```bash
source env.sh
export IGW_CHART_VERSION=v1.1.0
export GATEWAY_PROVIDER=none

helm install vllm-qwen25-15b-instruct \
  --kube-context ${CONTEXT} \
  --set inferencePool.modelServers.matchLabels.app=vllm-qwen25-15b-instruct \
  --set provider.name=${GATEWAY_PROVIDER} \
  --version ${IGW_CHART_VERSION} \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool
```

Verify:

```bash
kubectl --context ${CONTEXT} get inferencepool
```

### 5.5 Deploy Gateway + HTTPRoute

```bash
source env.sh
kubectl --context ${CONTEXT} apply -f inference_extension/inference-gateway.yaml
```

### 5.6 Test Inference Extension

```bash
source env.sh
IP=$(kubectl --context ${CONTEXT} get gateway/inference-gateway -o jsonpath='{.status.addresses[0].value}')

curl -s ${IP}:80/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "prompt": "What is the warmest city in the USA?",
    "max_tokens": 100,
    "temperature": 0.5
  }' | jq .
```

See `inference_extension/README.md` for architecture details on replacing vLLM's built-in router with model-aware load balancing at the gateway layer.

