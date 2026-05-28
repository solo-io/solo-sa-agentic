## MCP Tool Selection

## BYOK

BYOK (Bring Your Own Key) lets the GitHub Copilot SDK authenticate to your chosen LLM provider (OpenAI, Anthropic, Gemini, Azure OpenAI, etc.) using **your** API key instead of GitHub-managed credentials. The Copilot SDK reads the key from its provider configuration and signs LLM requests with it directly.

[Supported providers as of May, 2026](https://docs.github.com/en/copilot/how-tos/copilot-sdk/authenticate-copilot-sdk/bring-your-own-key)

![](../../images/BYOK.png)


- **One key, many models.** The Copilot SDK doesn't need a separate key for OpenAI, Anthropic, Bedrock. Agentgateway fronts all of them. Add a provider, no SDK change.
- **Per-user / per-team controls.** RBAC, rate limits, audit by JWT claim or header, which is invisible to the SDK.
- **Model aliasing.** The SDK requests `"smart"` or `"default"`; agentgateway resolves to the concrete model. Easy to swap models without redeploying anything client-side.
- **Failover.** OpenAI degrades → traffic shifts to Anthropic. SDK sees no change.


This end-to-end demo covers the customer's OpenAI key lives in a Kubernetes `Secret` inside agentgateway; the Copilot SDK only knows about the gateway.

**1. Upstream provider key as a Secret (the only place it lives):**

```bash
export OPEANI_API_KEY=
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: openai-api-key
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: $OPEANI_API_KEY
```

**2. Gateway listener (where the Copilot SDK connects):**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: byok-gateway
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: openai-compat
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

**3. AIBackend pointing at OpenAI:**

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: byok-openai
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai: {}                                 # model taken from request
      # no host/port → defaults to api.openai.com:443
```

**4. HTTPRoute wiring the Gateway to the Backend:**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: byok-openai-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: byok-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1                            # OpenAI-compatible path
      backendRefs:
        - group: gateway.agentgateway.dev
          kind: AgentgatewayBackend
          name: byok-openai
```

**5. AgentgatewayPolicy attaching the upstream credential to the Backend:**

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: byok-openai-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: AgentgatewayBackend
      name: byok-openai
  backend:
    auth:
      secretRef:
        name: openai-api-key                     # attached to upstream call
```

**6. Copilot SDK pointed at the gateway, NOT at OpenAI:**

```jsonc
// copilot-sdk.config.json (or equivalent for your SDK language)
{
  "providers": {
    "openai": {
      "baseURL": "http://<gateway-external-ip>/v1",
      // Token the SDK presents to agentgateway — NOT the OpenAI key.
      // Can be an internal JWT, an API key in a Secret, or omitted if mTLS.
      "apiKey":  "sdk-to-gateway-token"
    }
  }
}
```

**7. Smoke test (curl, no SDK needed):**

```bash
export GW_IP=$(kubectl get gateway byok-gateway -n agentgateway-system \
  -o jsonpath='{.status.addresses[0].value}')

curl -sS "http://${GW_IP}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role":"user","content":"Say hello from BYOK."}]
  }' | jq -r '.choices[0].message.content'
```

If you see a normal completion, the path **Copilot SDK → agentgateway → OpenAI** is working and the SDK has zero knowledge of `sk-proj-…`.

## OBO

On-Behalf-Of (OBO) is the pattern where an agent makes downstream calls carrying **two identities** at once:

- **`sub`** — the user the agent is acting for
- **`act`** — the agent itself (RFC 8693 §4.1)

The downstream service (a tool, an MCP server, an API) can then enforce policy on either or both. This is what makes "agent identity" tangible — without OBO, downstream services only see the agent and lose the human, or only see the human and lose the agent.

### OBO Flow

Two flavors of OBO show up in this stack — they differ in *who mints the OBO token*, but agentgateway sees the same shape on the wire.

**Flavor 1 — GitHub Copilot (real OAuth OBO):** the GitHub Copilot SDK obtains a delegated token via GitHub's OAuth token endpoint (or an enterprise IdP configured for it). The token's `act` claim identifies Copilot; `sub` identifies the GitHub user. Standards-track RFC 8693 token exchange.

**Flavor 2 — kagent-enterprise (self-minted OBO JWT):** kagent's middleware (`middleware/pkg/oidc/obo.go`) signs an OBO JWT with its own RSA key when forwarding a user request to a downstream agent or MCP server. kagent publishes the public key at `/jwks.json` for verifiers. Not RFC 8693 — kagent is acting as a mini IdP for its own agents.

In both cases the downstream call that hits agentgateway has the same observable property: a JWT whose `sub` is the user and `act.sub` is the agent. agentgateway's CEL RBAC sees both and gates per-tool access accordingly.

```
┌──────────┐                                                  ┌────────────────┐
│  User    │  user JWT (sub=alice)                            │   IdP / kagent │
│ (Alice)  │ ───────────────────────────────────────────────▶ │   (token mint) │
└──────────┘                                                  └────────┬───────┘
                                                                       │ OBO JWT:
                                                                       │   sub  = alice
                                                                       │   act  = { sub: <agent> }
                                                                       ▼
                                                              ┌────────────────┐
                                                              │     Agent      │
                                                              │  (Copilot or   │
                                                              │   kagent agent)│
                                                              └────────┬───────┘
                                                                       │ OBO JWT in Authorization
                                                                       ▼
                                                              ┌────────────────┐
                                                              │  agentgateway  │
                                                              │  - validates   │
                                                              │  - CEL on sub  │
                                                              │  - CEL on act  │
                                                              └────────┬───────┘
                                                                       │ (forwarded to MCP/tool/API)
                                                                       ▼
                                                              ┌────────────────┐
                                                              │   MCP server   │
                                                              │   / HTTP API   │
                                                              └────────────────┘
```

The agentgateway-side code lives at `crates/agentgateway/src/http/jwt.rs` (JWT validation), `crates/agentgateway/src/mcp/rbac.rs` (per-tool authorization), and `ent-controller/internal/tokenexchange/` (the STS implementation if you want agentgateway itself to perform a token exchange step before forwarding).

### OBO Flow demo — kagent flavor

This is the easier flavor to demo locally because kagent-enterprise is already installed and mints OBO tokens automatically. The goal: see an OBO JWT in flight, decode it, and verify agentgateway is enforcing claims from it.

**1. Enable OBO in kagent (ConfigMap):**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kagent-config
  namespace: kagent
data:
  # OBO is on by default; this is the explicit form.
  SKIP_OBO: "false"
  # Comma-separated extra claims to propagate from the user's OIDC token
  # into the OBO token (in addition to the standard sub/act/iss/aud/exp).
  OBO_CLAIMS_TO_PROPAGATE: "email,groups,preferred_username"
```

**2. Verify kagent's JWKS endpoint is serving keys:**

```bash
kubectl port-forward -n kagent svc/kagent 8080:8080 >/dev/null 2>&1 &
curl -sS http://localhost:8080/jwks.json | jq .
# Expect: { "keys": [ { "kty": "RSA", "kid": "...", "n": "...", "e": "AQAB", ... } ] }
```

This is the URL agentgateway will fetch to validate kagent-minted OBO tokens.

**3. Capture an OBO token mid-flight:**

The easiest way is to attach a debug echo backend that just dumps the request headers. Drop this in a scratch namespace:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: demo-ns }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
        - name: echo
          image: mendhak/http-https-echo:34
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: demo-ns }
spec:
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 8080 }]
```

Then make any request that flows through kagent → echo and look at the `Authorization` header on the echo side. That's your OBO JWT.

**4. What an OBO JWT from kagent looks like (decoded):**

```jsonc
// Header
{ "alg": "RS256", "kid": "kagent-2026-05-key-1", "typ": "JWT" }

// Payload
{
  "iss":  "kagent.kagent",                                          // kagent's issuer
  "sub":  "alice@example.com",                                      // the human user
  "aud":  "demo-ns",                                                // downstream audience
  "act":  {
    "sub": "system:serviceaccount:demo-ns:research-agent"           // THE AGENT
  },
  "iat":  1748448000,
  "nbf":  1748448000,
  "exp":  1748534400,                                               // 24h default
  "email":          "alice@example.com",                            // propagated claim
  "groups":         ["dev","platform"],                             // propagated claim
  "preferred_username": "alice"                                     // propagated claim
}
```

Paste it into `jwt.io` to verify the signature against the JWKS from step 2.

**5. agentgateway side — validate the OBO JWT:**

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: kagent-obo-jwt-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: EnterpriseAgentgatewayBackend
      name: docs-mcp                    # any backend you want OBO-gated
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "kagent.kagent"
          audiences: ["demo-ns"]
          jwks:
            url: "http://kagent.kagent.svc.cluster.local:8080/jwks.json"
            cacheDuration: 5m
```

Once this is applied, any request to that backend without a valid kagent OBO JWT is rejected at the gateway. With it, `jwt.sub` and `jwt.act.sub` are in scope for every downstream CEL rule (see the "OBO Agent/tool isolation for MCP" section below for the per-tool RBAC layer).

### OBO Flow demo — Copilot flavor (sketch)

Real Copilot OBO requires an enterprise IdP wired into the GitHub Copilot Enterprise tenant. The agentgateway-side YAML is structurally identical to the kagent flavor — only `issuer`, `audiences`, and `jwks.url` change:

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: copilot-obo-jwt-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: EnterpriseAgentgatewayBackend
      name: docs-mcp
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "https://login.microsoftonline.com/<tenant-id>/v2.0"   # or your IdP
          audiences: ["api://copilot-downstream"]                        # what your IdP sets
          jwks:
            url: "https://login.microsoftonline.com/<tenant-id>/discovery/v2.0/keys"
            cacheDuration: 5m
```

The decoded Copilot OBO token will have a comparable shape — `sub` = the GitHub/Entra user, `act.sub` = the Copilot service principal — but the exact issuer URL and claim formats depend on your IdP. Have the customer share a sample decoded token from their tenant before committing to specific `audiences` and `issuer` values.

### Agent Identity With OBO

This also covers the customer ask: **agent isolation** — "if it's this agent identity, only allow these MCP server tools."

The mechanism is `backend.mcp.authorization` on an `AgentgatewayPolicy`, evaluating CEL expressions where `jwt.sub` is the user and `jwt.act.sub` is the agent. With one or more `Allow` rules present, the policy becomes **deny-by-default** — every other tool is invisible to the agent.

**Copilot agent:**

```yaml
matchExpressions:
  - 'jwt.act.sub == "github-copilot" && mcp.tool.name in ["search", "fetch_doc"]'
```

**kagent agent (note the K8s ServiceAccount format kagent's OBO middleware uses):**

```yaml
matchExpressions:
  - 'jwt.act.sub == "system:serviceaccount:demo-ns:research-agent" && mcp.tool.name in ["search", "fetch_doc"]'
```

Same backend, same MCP server, two agents — each gets a different visible toolset. The killer feature: **`list_tools` filters per-item**, so `research-agent` doesn't even *see* the tools it can't call; it never has to attempt a forbidden call and get a 403.

### OBO Agent/tool isolation for MCP

A complete, working example. Backend exposes 4 hypothetical MCP tools (`search`, `fetch_doc`, `create_doc`, `delete_doc`); policy restricts each agent to a subset based on its `act` claim.

```yaml
---
# Backend pointing at a real MCP server (StreamableHTTP)
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: docs-mcp
  namespace: agentgateway-system
spec:
  entMcp:
    targets:
      - name: docs
        static:
          host: docs-mcp.demo-ns.svc.cluster.local
          port: 8080
          protocol: StreamableHTTP
---
# JWT authentication — validates whichever issuer is minting the OBO token.
# For Copilot, this is your enterprise IdP. For kagent, this is kagent's /jwks.json.
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: docs-mcp-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: EnterpriseAgentgatewayBackend
      name: docs-mcp
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "kagent.kagent"                     # kagent's iss claim
          audiences: ["docs-mcp"]
          jwks:
            url: "http://kagent.kagent.svc.cluster.local:8080/jwks.json"
            cacheDuration: 5m
      mcp:
        # publishes /.well-known/oauth-protected-resource for MCP clients
        resourceMetadata: {}
---
# Per-agent tool isolation. With ≥1 Allow rule, this is deny-by-default.
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: docs-mcp-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: EnterpriseAgentgatewayBackend
      name: docs-mcp
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            # Read-only research agent — search + fetch only
            - 'jwt.act.sub == "system:serviceaccount:demo-ns:research-agent"
                && mcp.tool.name in ["search", "fetch_doc"]'
            # Writer agent — full read/write but no delete, scoped to its user
            - 'jwt.act.sub == "system:serviceaccount:demo-ns:writer-agent"
                && mcp.tool.name in ["search", "fetch_doc", "create_doc"]'
            # GitHub Copilot (when Copilot is the agent in OBO)
            - 'jwt.act.sub == "github-copilot"
                && mcp.tool.name in ["search", "fetch_doc"]'
```

**What this demonstrates on stage:**

1. Connect MCP Inspector as `research-agent` (OBO token with `act.sub = system:serviceaccount:demo-ns:research-agent`) → `tools/list` returns `["search", "fetch_doc"]`.
2. Connect as `writer-agent` (same user!) → `tools/list` returns `["search", "fetch_doc", "create_doc"]`.
3. Try calling `delete_doc` from either → denied. The tool isn't even visible.
4. Swap the issuer to your enterprise IdP and re-run as Copilot — same enforcement, different `act` value.

The user identity (`jwt.sub`) is also available — if you want "writer-agent can only create docs for *its own* user," add `&& mcp.tool.name == "create_doc" && jwt.sub == request.headers["x-resource-owner"]` or similar.

## Intent-Based Routing

Intent-based routing lets agentgateway decide *which* LLM model serves a given request — based on the user, the agent, the prompt size, or the workload type — without the caller having to choose. The Copilot SDK (or kagent agent) requests a stable model name like `"default"`, and agentgateway resolves it to a concrete model per request.

### What's available at request transformation time (verified)

CEL transformations on the `model` field run **before** the upstream LLM call. The CEL context at that point includes:

- `llm.requestModel` — what the client asked for
- `llm.provider` — the resolved provider
- `request.headers[...]` — any client-provided header
- `request.body` — the raw request body (use `size(request.body)` for payload-size estimation)
- `llm.prompt` — the parsed prompt content, **only** if prompt-capture is enabled elsewhere (prompt guard, logging); otherwise `None`
- JWT claims — `jwt.sub`, `jwt.act.sub`, `jwt.claims.*` — present whenever JWT auth runs first

**Important: `llm.inputTokens` is NOT populated at request time.** Token counts are computed downstream of the transformation step. Don't write rules like `llm.inputTokens > 8000 ? ...` — they evaluate against zero/unset and the demo will silently route everything to the cheap branch. Use `size(request.body)` as a coarse proxy if you need a "big prompt → big model" rule, or have the caller send a hint header.

(Verified in `crates/agentgateway/src/proxy/httpproxy.rs:300` — transformations run before `llm/mod.rs:887` where LLMInfo with token counts is created.)

### Example — testable intent routing

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: copilot-intent-routing
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: AgentgatewayBackend
      name: llm-backend
  ai:
    # 1. Friendly model aliases — clients ask for these stable names.
    modelAliases:
      default: gpt-4o-mini
      smart: claude-sonnet-4-6
      local: qwen2.5-1.5b-instruct

    # 2. Dynamic per-request routing. Transformations OVERWRITE the model field
    #    after aliases are resolved, so anything decided here is final.
    transformations:
      - field: model
        expression: >
          // Tier-based: premium users always get the strong model.
          request.headers["x-user-tier"] == "premium"
            ? "claude-sonnet-4-6"

          // Agent-based: the research agent (read-heavy) gets the cheap model;
          // the writer agent (generation-heavy) gets the strong one.
          : jwt.act.sub == "system:serviceaccount:demo-ns:writer-agent"
            ? "claude-sonnet-4-6"
          : jwt.act.sub == "system:serviceaccount:demo-ns:research-agent"
            ? "gpt-4o-mini"

          // Size-based: large requests route to the high-context model.
          // size(request.body) is in BYTES, not tokens — calibrate per workload.
          : size(request.body) > 20000
            ? "claude-sonnet-4-6"

          // Internal self-hosted route for low-stakes requests from the
          // "automation" header (e.g. CI / scheduled tasks).
          : request.headers["x-workload"] == "automation"
            ? "qwen2.5-1.5b-instruct"

          // Default fallback.
          : "gpt-4o-mini"
```

### What you can demo with this

1. **Same client request, different model.** Two `curl`s to the same endpoint with the same body, differing only in `x-user-tier: premium` → response model differs. Show the model name in the response.
2. **Agent identity drives routing.** Same user, two agents in OBO flow → research-agent gets the cheap model, writer-agent gets the strong one. Token cost difference visible in logs/metrics.
3. **Payload size flip.** Short prompt → cheap model. Long prompt (paste a wall of text) → strong model.
4. **Aliases hide the providers.** Client only ever sees `default`, `smart`, `local`. Swap the underlying concrete models in the YAML — no client change.

### What this is NOT

This is *rule-based* routing — fast, deterministic, no extra LLM call. It is **not** semantic intent classification ("the prompt is about code → use a code model"). agentgateway has no built-in classifier or embeddings router. If the customer needs that, the pattern is:

- Add a "router model" first hop (a small fast model that classifies and returns the target model name)
- Have the caller include a classification header (`x-intent: code-gen` / `x-intent: summarization`) decided client-side
- Or use the `Detect` route type to capture metadata and route via an external decision service

For most "hide model selection from users" asks, header + JWT + size-based rules cover 80% of the value without that complexity.



## Routing From GitHub Copilot through agw

This section is the LLM-side companion to BYOK. When the Copilot SDK is pointed at agentgateway (instead of directly at OpenAI/Anthropic), agentgateway becomes responsible for picking the upstream model and provider on every request. The customer wants two flavors served from a single endpoint:

- **Public models** — OpenAI, Anthropic, Azure OpenAI, Bedrock, etc.
- **Self-hosted models** — vLLM, TGI, or any OpenAI-compatible local inference server.

The `AIBackend` type supports both, in priority groups, with automatic failover. The cluster already has `vllm-gpt-oss-20b` and `vllm-qwen25-15b-instruct` deployed as InferencePools — they're the self-hosted side of this example.

### Public models — single backend fronting multiple providers

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: llm-public
  namespace: agentgateway-system
spec:
  ai:
    groups:
      # Primary group — OpenAI is the default upstream.
      - providers:
          - name: openai-primary
            openai: {}                              # model taken from request
            policies:
              auth:
                secretRef:
                  name: openai-api-key              # holds OPENAI_API_KEY
          - name: anthropic-primary
            anthropic: {}
            policies:
              auth:
                secretRef:
                  name: anthropic-api-key
      # Failover group — Azure OpenAI same models, different region.
      - providers:
          - name: azure-failover
            azureopenai:
              endpoint: ai-gateway-failover.openai.azure.com
              apiVersion: "2024-02-15-preview"
              deploymentName: gpt-4o-mini
            policies:
              auth:
                secretRef:
                  name: azure-openai-key
```

Provider selection within a group is health-weighted (`select_provider()` samples two endpoints, picks higher health). On consecutive failures, the group is evicted and the next priority group takes traffic. The client sees one stable endpoint.

### Self-hosted models — vLLM via OpenAI-compatible API

vLLM exposes an OpenAI-compatible `/v1/chat/completions`, so the `openai` provider type works with a custom `host`:

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: llm-selfhosted
  namespace: agentgateway-system
spec:
  ai:
    groups:
      - providers:
          - name: vllm-qwen
            openai:
              model: qwen2.5-1.5b-instruct          # pin to the served model
            host: vllm-qwen25-15b-instruct.default.svc.cluster.local
            port: 8000
            # No auth — in-cluster service, no API key.
          - name: vllm-gpt-oss
            openai:
              model: gpt-oss-20b
            host: vllm-gpt-oss-20b.default.svc.cluster.local
            port: 8000
```

### Combined — one backend that does both

A single backend can mix public and self-hosted in priority groups. Pattern: self-hosted first for low-stakes / data-sensitive workloads, public as failover:

```yaml
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: llm-backend
  namespace: agentgateway-system
spec:
  ai:
    groups:
      # Group 0 — try self-hosted first (cheap, private, no per-token cost).
      - providers:
          - name: vllm-qwen
            openai:
              model: qwen2.5-1.5b-instruct
            host: vllm-qwen25-15b-instruct.default.svc.cluster.local
            port: 8000
      # Group 1 — fall back to public when self-hosted is degraded or evicted.
      - providers:
          - name: openai-public
            openai: {}
            policies:
              auth:
                secretRef:
                  name: openai-api-key
---
# Layer the aliases + transformations from "Intent-Based Routing" on top.
apiVersion: gateway.agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: llm-routing
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: AgentgatewayBackend
      name: llm-backend
  ai:
    modelAliases:
      default: qwen2.5-1.5b-instruct
      smart: gpt-4o
      local: qwen2.5-1.5b-instruct
    transformations:
      - field: model
        expression: >
          request.headers["x-user-tier"] == "premium"
            ? "gpt-4o"
          : request.headers["x-workload"] == "automation"
            ? "qwen2.5-1.5b-instruct"
          : "qwen2.5-1.5b-instruct"
```

### Pointing GitHub Copilot at this backend

In the Copilot SDK's BYOK provider configuration, set the OpenAI-compatible `baseURL` to the agentgateway listener:

```
baseURL: https://<gateway-external-ip>/v1
apiKey:  <internal-token-or-mTLS>     # what the SDK presents to agentgateway, NOT the upstream key
```

The SDK now uses agentgateway as an OpenAI-compatible endpoint. Underneath, agentgateway:

1. Authenticates the request (JWT / API key / mTLS, per the `traffic.jwtAuthentication` or auth policy).
2. Resolves `modelAliases` and applies `transformations` to pick the concrete model.
3. Selects a healthy provider from the priority groups, attaching the upstream's API key from the referenced `Secret`.
4. Forwards the request, normalizes the response if needed (Completions ↔ Messages format), and returns.

### What this story sells

- **One Copilot config, all models.** Public + self-hosted under one endpoint. No SDK redeploy when you add Bedrock.
- **Data residency on demand.** Default to self-hosted; only fail over to public when local is down.
- **Cost control.** Self-hosted handles the volume; expensive public models handle premium / overflow traffic.
- **Compliance traceability.** Every request through the gateway is logged with user (`jwt.sub`), agent (`jwt.act.sub`), chosen model, provider, token counts.