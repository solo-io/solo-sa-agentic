# Semantic Model Routing With Enterprise Agentgateway

Route LLM traffic to the *right* model per request using enterprise agentgateway on Kubernetes: expensive frontier models (Claude Opus 4.8, GPT-5.5) only when the request actually needs them, a cheaper default (Claude Sonnet 5) for everything else. Clients call one stable endpoint; the gateway classifies the request and picks the concrete model.

Enterprise agentgateway does not ship a first-party embedding-based semantic classifier. What it ships is the routing machinery:

- **`EnterpriseAgentgatewayBackend`** with an `ai` spec: one backend per model, or **priority groups** for health-based failover.
- **`HTTPRoute`**: weighted splits and header-based routing across AI backends.
- **`EnterpriseAgentgatewayPolicy`** with **`phase: PreRouting`**: transformation (CEL) or `extProc` that runs *before* route selection, so a derived intent header can drive the routing decision.

The pattern: a PreRouting policy classifies the request and sets `x-intent`; the HTTPRoute matches on `x-intent` and steers to the right model backend. Swap the CEL classifier for an `extProc` server and the same wiring becomes true semantic routing.x

## Quick Vocab

- **`EnterpriseAgentgatewayBackend`** (`enterpriseagentgateway.solo.io/v1alpha1`): a backend definition. For LLMs, `spec.ai.provider.<anthropic|openai|gemini|bedrock|...>` with optional `model` override; `spec.policies.auth.secretRef` for credentials. `spec.ai.groups` instead of `provider` gives priority-ordered provider groups. The `ai` spec is identical to the OSS `AgentgatewayBackend`; the enterprise kind additionally supports `entMcp` backends and `tokenExchange`/`workloadIdentity` backend auth.
- **`EnterpriseAgentgatewayPolicy`** (`enterpriseagentgateway.solo.io/v1alpha1`): attaches traffic policies to a Gateway/route. `spec.traffic.phase: PreRouting` runs the policy before route selection (default is `PostRouting`).
- **Transformation**: `spec.traffic.transformation.request.set` sets request headers from CEL expressions (request headers, JWT claims, or the request body via `json(request.body)`).
- **Priority groups**: within a group, providers are weighted automatically by health; if a whole group degrades, traffic shifts to the next group.

## Prerequisites

- A cluster running Solo Enterprise for Agentgateway (this was built against `enterprise-agentgateway` v2026.6.3):

```bash
kubectl get gatewayclass enterprise-agentgateway
kubectl get crd enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io
```

- An Anthropic API key and an OpenAI API key
- `curl` and `jq`

## Step 1: Namespace and provider secrets

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

## Step 2: Model backends

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
        policies:
          auth:
            secretRef:
              name: anthropic-secret
    - providers:
      - name: fallback-gpt-5-mini
        openai:
          model: gpt-5-mini
        policies:
          auth:
            secretRef:
              name: openai-secret
EOF
```

The `model` field on the provider overrides whatever model the client sends. The backend *is* the model choice, which is what lets the route decide.

## Step 3: Gateway and routes

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

## Step 4: PreRouting intent classifier

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

This mirrors the pattern enterprise agentgateway uses in its own e2e suite: a PreRouting policy sets a header from a JWT claim (`jwt.tier`) and the HTTPRoute routes premium users to a different backend (`ent-controller/test/e2e/features/agentgateway/policies/testdata/jwt-transform-routing-policy.yaml`).

## Step 5: Verify status

```bash
kubectl get enterpriseagentgatewaybackends,httproutes,gateway -n semantic-routing
kubectl get enterpriseagentgatewaypolicy intent-classifier -n semantic-routing
```

Expect every backend `ACCEPTED: True`, the Gateway `PROGRAMMED: True` (a proxy pod and a LoadBalancer Service appear in the namespace), and the policy `ACCEPTED: True / ATTACHED: True`.

## Step 6: Send traffic

Port-forward (or use the LoadBalancer address once assigned):

```bash
kubectl port-forward -n semantic-routing svc/semantic-routing 8080:8080 &
```

Intent-based routing: same endpoint, different models.

```bash
# Explicit intent header: escalates to the expensive model -> claude-opus-4-8
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -H 'x-intent: code' \
  -d '{"model":"any","messages":[{"role":"user","content":"write a binary search in Go"}]}' | jq -r .model

# No header; the PreRouting CEL classifier detects "prove" -> gpt-5.5
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"prove sqrt(2) is irrational"}]}' | jq -r .model

# Generic prompt: stays on the cheaper default -> claude-sonnet-5
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

> **Dry-run trick (no valid keys needed):** routing happens before provider auth, so even with placeholder keys you can prove where a request landed by the provider's 401 signature. Anthropic returns `{"error":{"type":"invalid_request_error","message":"invalid x-api-key"}}`, OpenAI returns `"Incorrect API key provided: ..."`. Useful when demoing routing logic without burning tokens.

## From Keyword CEL To True Semantic Routing

Three rungs, all using the same HTTPRoute wiring; only the classifier changes:

1. **Client-declared intent**: the app sends `x-intent` itself. Zero gateway logic; you trust the caller.
2. **Gateway CEL heuristics** (this demo): PreRouting transformation derives `x-intent` from headers, JWT claims, or `json(request.body)`. Deterministic, no extra hops, limited semantics.
3. **External classifier via `extProc`**: replace `transformation` with `extProc` in the same PreRouting policy, pointing at a gRPC classifier service (e.g., an embedding-based intent model such as the vLLM Semantic Router, which speaks the ext_proc protocol). The processor inspects the prompt, sets `x-intent` (or rewrites the body), and route matching proceeds on the mutated request. Enterprise WAF is built on this exact hook, and `extProc` also supports CEL-conditional execution (`conditional` entries) to run different classifiers for different traffic.

```yaml
# Sketch: same policy slot, extProc instead of transformation
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: semantic-routing
  traffic:
    phase: PreRouting
    extProc:
      backendRef:
        name: semantic-classifier   # your gRPC ext_proc Service
        port: 9000
```

## Cleanup

```bash
kubectl delete namespace semantic-routing
```

This removes the Gateway (and its LoadBalancer), all backends, routes, policies, and secrets.

## Source References (agentgateway-enterprise repo)

| What | Where |
|---|---|
| `EnterpriseAgentgatewayBackend` spec (embeds the upstream `AIBackend`) | `ent-controller/api/v1alpha1/enterpriseagentgateway/enterprise_agentgateway_backend_types.go` (~line 46) |
| AI spec, priority groups, `NamedLLMProvider` (upstream types) | `controller/api/v1alpha1/agentgateway/agentgateway_backend_types.go` (~lines 150–260) |
| Backend auth (`secretRef` under `Authorization` key) | `controller/api/v1alpha1/agentgateway/agentgateway_policy_types.go` (`BackendAuth`, ~line 1308) |
| `PreRouting` phase + allowed policies (transformation, extProc, …) | `ent-controller/api/v1alpha1/enterpriseagentgateway/enterprise_agentgateway_policy_types.go` (~line 614) |
| PreRouting transform-then-route e2e example | `ent-controller/test/e2e/features/agentgateway/policies/testdata/jwt-transform-routing-policy.yaml` |
| AI backend + HTTPRoute e2e example | `ent-controller/test/e2e/features/agentgateway/budget/testdata/setup.yaml` |
| ext_proc data-plane implementation | `crates/agentgateway/src/http/ext_proc.rs` |
| PreRouting runs before route selection | `crates/agentgateway/src/proxy/httpproxy.rs` (gateway policies ~841, route selection ~855) |
| Virtual models = standalone-only (XDS sets no model router) | `crates/agentgateway/src/types/agent_xds.rs` (~line 1346) |
