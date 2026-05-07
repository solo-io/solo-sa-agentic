# Inference Extension — AGW Enterprise + vLLM

Use Solo Enterprise for AgentGateway with the Kubernetes Gateway API Inference Extension to route requests to self-hosted LLM workloads (e.g. vLLM). This replaces vLLM's built-in router with model-aware, KV-cache-aware load balancing at the gateway layer.

Docs: https://docs.solo.io/agentgateway/2.1.x/inference/#before-you-begin

## Architecture

```
                                    InferencePool
                                  ┌─────────────────────────┐
Client ──► AGW Gateway ──► HTTPRoute ──► │  EPP (Endpoint Picker)  │
                                  │  ┌──────┐ ┌──────┐      │
                                  │  │vLLM-1│ │vLLM-2│ ...  │
                                  └──┴──────┴─┴──────┴──────┘
```

1. Client sends inference request to the AGW Gateway
2. HTTPRoute routes to the `InferencePool` backend
3. The Endpoint Picker (EPP/llm-d) selects the best vLLM pod based on load, KV-cache usage, and model availability
4. AGW proxies the request to the selected pod

## What It Replaces

| Without Inference Extension | With Inference Extension |
|----|-----|
| vLLM built-in router distributes across replicas | EPP handles model-aware routing at the gateway |
| No visibility into KV-cache utilization | Routes to pod with most available GPU memory |
| LoRA adapters re-loaded on each request | Routes to pod that already has the adapter loaded |
| Separate load balancer + vLLM router | Single layer: AGW + EPP |

## Key CRDs

| CRD | API Group | Description |
|-----|-----------|-------------|
| `InferencePool` | `inference.networking.k8s.io` | Groups vLLM pods into a routable backend, references the EPP |
| `InferenceModel` | `inference.networking.k8s.io` | Maps model name → vLLM pods with version, criticality, weight |

## Setup

### Prerequisites

- AGW Enterprise installed (already done on this cluster)
- Inference Extension CRDs installed (already done: v1.5.0)

### Step 1: Enable Inference Extension in AGW

```bash
source ../env.sh

helm --kube-context "${CONTEXT}" upgrade -i -n "${AGW_NAMESPACE}" --version "v${AGW_VERSION}" \
  enterprise-agentgateway \
  "${AGW_HELM_REGISTRY}/enterprise-agentgateway" \
  --set inferenceExtension.enabled=true \
  --reuse-values
```

### Step 2: Deploy vLLM (CPU mode for local testing)

```bash
kubectl --context ${CONTEXT} apply -f vllm-qwen.yaml
```

Wait 2-3 minutes for the Qwen model to download, then verify:

```bash
kubectl --context ${CONTEXT} get pods -l app=vllm-qwen25-15b-instruct
```

### Step 3: Deploy InferencePool + EPP via Helm

```bash
export IGW_CHART_VERSION=v1.1.0
export GATEWAY_PROVIDER=none

helm install vllm-qwen25-15b-instruct \
  --kube-context ${CONTEXT} \
  --set inferencePool.modelServers.matchLabels.app=vllm-qwen25-15b-instruct \
  --set provider.name=$GATEWAY_PROVIDER \
  --version $IGW_CHART_VERSION \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool

kubectl --context ${CONTEXT} get inferencepool
```

### Step 4: Deploy Gateway + HTTPRoute

```bash
kubectl --context ${CONTEXT} apply -f inference-gateway.yaml
```

### Step 5: Test

```bash
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

## Resource Requirements

The vLLM CPU image requires significant resources:

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 11 cores | 11 cores |
| Memory | 10Gi | 10Gi |

The Kind cluster worker node must have enough capacity. For GPU-based testing, use a proper vLLM GPU image instead.

## Benefits

- **Unified gateway**: AGW handles auth, rate limiting, guardrails AND inference routing in one layer
- **Model-aware LB**: Routes to the least-loaded vLLM replica based on KV-cache utilization
- **LoRA routing**: Routes to the replica that already has the requested adapter loaded (avoids cold-load latency)
- **Observability**: All inference traffic visible in AGW metrics/logs
