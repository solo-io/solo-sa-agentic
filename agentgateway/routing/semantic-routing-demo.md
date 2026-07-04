# Semantic Model Routing With Enterprise Agentgateway

Route LLM traffic to the *right* model per request using agentgateway on Kubernetes: expensive frontier models (Claude Opus 4.8, GPT-5.5) only when the request actually needs them, a cheaper default (Claude Sonnet 5) for everything else. Clients call one stable endpoint; the gateway classifies the request and picks the concrete model.

Enterprise agentgateway does not ship a first-party embedding-based semantic classifier. What it ships is the routing machinery:

- **`EnterpriseAgentgatewayBackend`** with an `ai` spec: one backend per model, or **priority groups** for health-based failover.
- **`HTTPRoute`**: weighted splits and header-based routing across AI backends.
- **`EnterpriseAgentgatewayPolicy`** with **`phase: PreRouting`**: transformation (CEL) or `extProc` that runs *before* route selection, so a derived intent header can drive the routing decision.

The pattern: a PreRouting policy classifies the request and sets `x-intent`; the HTTPRoute matches on `x-intent` and steers to the right model backend. For true semantic classification, the same `extProc` hook plugs in the vLLM Semantic Router (last section).

## Quick Vocab

- **`EnterpriseAgentgatewayBackend`** : a backend definition. For LLMs, `spec.ai.provider.<anthropic|openai|gemini|bedrock|...>` with optional `model` override; `spec.policies.auth.secretRef` for credentials. `spec.ai.groups` instead of `provider` gives priority-ordered provider groups.
- **`EnterpriseAgentgatewayPolicy`**: attaches traffic policies to a Gateway/route. `spec.traffic.phase: PreRouting` runs the policy before route selection (default is `PostRouting`).
- **Transformation**: `spec.traffic.transformation.request.set` sets request headers from CEL expressions (request headers, JWT claims, or the request body via `json(request.body)`).
- **Priority groups**: within a group, providers are weighted automatically by health; if a whole group degrades, traffic shifts to the next group.

## Prerequisites

- A cluster running agentgateway

```bash
kubectl get gatewayclass enterprise-agentgateway
```

- An Anthropic API key and an OpenAI API key
- `helm` (for the vLLM Semantic Router install in the last section)
- `curl` and `jq`

## Semantic Route Model Selection With CEL

### Step 1: Namespace and provider secrets

The default Secret resolver requires the API key under the `Authorization` key. Export the keys as environment variables and create the Secrets imperatively so keys never land in a manifest file in plain text:

```bash
export ANTHROPIC_API_KEY='<your-anthropic-key>'
export OPENAI_API_KEY='<your-openai-key>'

kubectl create ns semantic-routing
kubectl create secret generic anthropic-secret -n semantic-routing \
  --from-literal=Authorization="$ANTHROPIC_API_KEY"
kubectl create secret generic openai-secret -n semantic-routing \
  --from-literal=Authorization="$OPENAI_API_KEY"
```

### Step 2: Model backends

One `EnterpriseAgentgatewayBackend` per model tier, plus one failover backend using priority groups. The tiers:

| Backend | Model | Role |
|---|---|---|
| `claude-opus` | `claude-opus-4-8` | expensive; only for requests that need it (code) |
| `gpt-5-5` | `gpt-5.5` | expensive; deep reasoning |
| `claude-sonnet` | `claude-sonnet-5` | cheaper default for everything else |
| `gpt-5-mini` | `gpt-5-mini` | cheap OpenAI tier; weighted split and failover fallback |

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: claude-opus
  namespace: semantic-routing
spec:
  ai:
    provider:
      anthropic:
        model: claude-opus-4-8
  policies:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: claude-sonnet
  namespace: semantic-routing
spec:
  ai:
    provider:
      anthropic:
        model: claude-sonnet-5
  policies:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: gpt-5-5
  namespace: semantic-routing
spec:
  ai:
    provider:
      openai:
        model: gpt-5.5
  policies:
    auth:
      secretRef:
        name: openai-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: gpt-5-mini
  namespace: semantic-routing
spec:
  ai:
    provider:
      openai:
        model: gpt-5-mini
  policies:
    auth:
      secretRef:
        name: openai-secret
---
# Failover: group order = priority. If every provider in the first group is
# degraded, traffic shifts to the next group. Within a group, providers are
# weighted automatically by health.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: resilient-failover
  namespace: semantic-routing
spec:
  ai:
    groups:
    - providers:
      - name: primary-claude-sonnet
        anthropic:
          model: claude-sonnet-5
    - providers:
      - name: fallback-gpt-5-mini
        openai:
          model: gpt-5-mini
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: resilient-failover-anthropic-auth
  namespace: semantic-routing
spec:
  targetRefs:
  - group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayBackend
    name: resilient-failover
    sectionName: primary-claude-sonnet
  backend:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: resilient-failover-openai-auth
  namespace: semantic-routing
spec:
  targetRefs:
  - group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayBackend
    name: resilient-failover
    sectionName: fallback-gpt-5-mini
  backend:
    auth:
      secretRef:
        name: openai-secret
EOF
```

The `model` field on the provider overrides whatever model the client sends. The backend *is* the model choice, which is what lets the route decide.

### Step 3: Gateway and routes

Three "virtual models", one hostname each:

| Hostname | Behavior |
|---|---|
| `smart.demo.internal` | intent-based: `x-intent: code` → claude-opus-4-8, `x-intent: deep-reasoning` → gpt-5.5, default → claude-sonnet-5 (cheaper) |
| `fast.demo.internal` | weighted 80/20 split: claude-sonnet-5 / gpt-5-mini |
| `resilient.demo.internal` | priority-group failover backend |

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: semantic-routing
  namespace: semantic-routing
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - name: http
    protocol: HTTP
    port: 8080
    allowedRoutes:
      namespaces:
        from: Same
---
# "smart": intent-based routing. x-intent is set by the PreRouting policy in
# Step 4 before this route match is evaluated.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: smart
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - smart.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
      headers:
      - name: x-intent
        value: code
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-opus
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
      headers:
      - name: x-intent
        value: deep-reasoning
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: gpt-5-5
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-sonnet
---
# "fast": weighted split across two cheap models.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fast
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - fast.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-sonnet
      weight: 80
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: gpt-5-mini
      weight: 20
---
# "resilient": health-based failover via the priority-group backend.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: resilient
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - resilient.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: resilient-failover
EOF
```

### Step 4: PreRouting intent classifier

This is the piece that makes it "semantic". `phase: PreRouting` runs the transformation *before* the HTTPRoute match, so the header it sets participates in routing. The CEL below respects a client-supplied `x-intent` and otherwise derives intent from the prompt content:

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: intent-classifier
  namespace: semantic-routing
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: semantic-routing
  traffic:
    phase: PreRouting
    transformation:
      request:
        set:
        - name: x-intent
          value: >-
            "x-intent" in request.headers ? request.headers["x-intent"] :
            (json(request.body).messages.exists(m, m.content.contains("code") || m.content.contains("function")) ? "code" :
            (json(request.body).messages.exists(m, m.content.contains("prove") || m.content.contains("theorem")) ? "deep-reasoning" : "general"))
EOF
```

Keyword CEL is deliberately simple; it's a stand-in for the classifier. The same PreRouting slot accepts an `extProc` policy instead, which is how you plug in a real semantic classifier (see [the ladder](#from-keyword-cel-to-true-semantic-routing)).

This mirrors the pattern from enterprise agentgateway's own e2e suite: a PreRouting policy sets a header from a JWT claim (`jwt.tier`) and the HTTPRoute routes premium users to a different backend (`ent-controller/test/e2e/features/agentgateway/policies/testdata/jwt-transform-routing-policy.yaml`).

### Step 5: Verify status

```bash
kubectl get enterpriseagentgatewaybackends,httproutes,gateway -n semantic-routing
kubectl get enterpriseagentgatewaypolicies -n semantic-routing
```

Expect every backend `ACCEPTED: True`, the Gateway `PROGRAMMED: True` (a proxy pod and a LoadBalancer Service appear in the namespace), and all three policies (`intent-classifier` plus the two failover auth policies) `ACCEPTED: True / ATTACHED: True`.

### Step 6: Send traffic

Port-forward (or use the LoadBalancer address once assigned):

```bash
kubectl port-forward -n semantic-routing svc/semantic-routing 8080:8080 &
```

Intent-based routing: same endpoint, different models.

- Explicit intent header: escalates to the expensive model -> claude-opus-4-8
- No header; the PreRouting CEL classifier detects "prove" -> gpt-5.5
- Generic prompt: stays on the cheaper default -> claude-sonnet-5
```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -H 'x-intent: code' \
  -d '{"model":"any","messages":[{"role":"user","content":"write a binary search in Go"}]}' | jq -r .model

curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"prove sqrt(2) is irrational"}]}' | jq -r .model

curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"say hi"}]}' | jq -r .model
```

The response `model` field shows the concrete model that served the request (the backend's `model` override wins regardless of what the client sent).

Weighted split (~80/20 over 10 calls):

```bash
for i in $(seq 1 10); do
  curl -s http://localhost:8080/v1/chat/completions \
    -H 'Host: fast.demo.internal' -H 'content-type: application/json' \
    -d '{"model":"any","messages":[{"role":"user","content":"hi"}]}' | jq -r .model
done | sort | uniq -c
```

Failover serves from `claude-sonnet-5` (priority group 0) while healthy, shifting to `gpt-5-mini` if Anthropic degrades:

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: resilient.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"hi"}]}' | jq -r .model
```

## vLLM Semantic Routing

This section uses vLLM Semantic Routing. The Semantic Router announces its decision by **rewriting the `model` field in the request body** (its `x-vsr-*` headers are response-side observability, not request routing signals). HTTPRoute matching can't see the body, so the router picks the *model*, not the *provider*: the route still decides which provider backend serves the request, and that backend must pass the router's model choice through instead of overriding it. Two consequences:

- The tiers collapse into one provider. Here: `claude-opus-4-8` vs `claude-sonnet-5`, chosen semantically, served through a single Anthropic backend **without** a `model` override. Cross-provider semantic steering (Claude vs GPT) would need a classifier that sets a routable header at PreRouting — the one thing the CEL rung can do that this rung can't.
- No PreRouting needed. Since the router doesn't influence *route* selection, its extProc policy attaches at the default `PostRouting` phase, scoped to a single HTTPRoute. `PreRouting` was only ever required to make a derived header visible to route matching.

### Rung 3a: deploy the vLLM Semantic Router

The router ships as a Helm chart ([integration guide](https://vllm-semantic-router.com/docs/installation/k8s/agentgateway)). This values file defines the two Anthropic model tiers and the decision rules that select between them; the router's built-in domain classifier (an embedding model, downloaded at startup) maps prompts to domains like `computer science` or `math`:

```bash
cat <<'EOF' > vsr-values.yaml
config:
  version: v0.3
  listeners: []
  providers:
    defaults:
      default_model: claude-sonnet-5   # cheap default for everything else
    models:
      - name: claude-opus-4-8
        backend_refs:
          - name: anthropic
            endpoint: api.anthropic.com:443
            weight: 1
      - name: claude-sonnet-5
        backend_refs:
          - name: anthropic
            endpoint: api.anthropic.com:443
            weight: 1
  routing:
    modelCards:
      - name: claude-opus-4-8
        modality: text
      - name: claude-sonnet-5
        modality: text
    decisions:
      - name: code
        description: Programming, debugging, and software engineering requests
        priority: 10
        rules:
          operator: OR
          conditions:
            - type: domain
              name: computer science
        modelRefs:
          - model: claude-opus-4-8
            use_reasoning: false
      - name: deep-reasoning
        description: Proofs, derivations, and formal analysis
        priority: 10
        rules:
          operator: OR
          conditions:
            - type: domain
              name: math
            - type: domain
              name: physics
            - type: domain
              name: philosophy
        modelRefs:
          - model: claude-opus-4-8
            use_reasoning: false
EOF

helm upgrade semantic-router oci://ghcr.io/vllm-project/charts/semantic-router \
  --version v0.0.0-latest \
  --namespace semantic-routing \
  -f vsr-values.yaml \
  --set persistence.storageClassName=default

kubectl wait --for=condition=Available deployment/semantic-router \
  -n semantic-routing --timeout=600s
```

The chart exposes a `semantic-router` Service with the ext_proc gRPC endpoint on port `50051`. The values above target the `v0.3` config schema; if you pin a different chart version, diff against the [chart's reference values](https://raw.githubusercontent.com/vllm-project/semantic-router/refs/heads/main/deploy/kubernetes/agentgateway/semantic-router-values/values.yaml).

### Rung 3b: a passthrough backend and route

The Step 2 backends each pin a `model`, which would clobber the router's choice. This backend omits it — whatever `model` the router writes into the body is what Anthropic serves:

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: claude-tiers
  namespace: semantic-routing
spec:
  ai:
    provider:
      anthropic: {}
  policies:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: semantic
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - semantic.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-tiers
EOF
```

The `smart`/`fast`/`resilient` routes from Step 3 are untouched; `semantic.demo.internal` is a fourth virtual model living alongside them.

### Rung 3c: attach the extProc policy

`requestBodyMode: Buffered` sends the router the full prompt to classify; buffered response mode lets it stamp its `x-vsr-*` decision headers on the response. Note what's *absent*: no `phase: PreRouting`. The router rewrites the body rather than steering the route, so the default PostRouting phase — scoped to just this HTTPRoute — is the right attachment point:

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: semantic-router
  namespace: semantic-routing
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: semantic
  traffic:
    extProc:
      backendRef:
        name: semantic-router
        port: 50051
      processingOptions:
        requestHeaderMode: Send
        requestBodyMode: Buffered
        responseHeaderMode: Send
        responseBodyMode: Buffered
        allowModeOverride: true
EOF
```

Buffered body modes disable streaming responses; if you need `stream: true`, use `FullDuplexStreamed` instead.

### Rung 3d: prove it beats keyword CEL

Clients send `"model": "auto"` and the router substitutes its decision. This prompt contains none of the rung-2 CEL keywords (`code`, `function`, `prove`, `theorem`), so the keyword classifier would have kept it on the cheap default — the embedding classifier recognizes a `computer science` prompt and escalates it:

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: semantic.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"why does my app keep crashing? here is the stack trace"}]}' | jq -r .model
# claude-opus-4-8

curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: semantic.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"say hi"}]}' | jq -r .model
# claude-sonnet-5
```

The router's decision metadata comes back as response headers:

```bash
curl -s -D - -o /dev/null http://localhost:8080/v1/chat/completions \
  -H 'Host: semantic.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"what is the derivative of x^3?"}]}' | grep -i x-vsr
# x-vsr-selected-category: math
# x-vsr-selected-model: claude-opus-4-8
```

## Cleanup

```bash
helm uninstall semantic-router -n semantic-routing
kubectl delete namespace semantic-routing
```

This removes the Gateway (and its LoadBalancer), all backends, routes, policies, secrets, and the Semantic Router deployment.
