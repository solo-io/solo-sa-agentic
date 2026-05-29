## For Observability/metrics shown in the UI

The kagent Dashboard reads from ClickHouse, which is fed by the `solo-enterprise-telemetry-collector` (in the `kagent` namespace). The collector receives OTLP spans + access logs from agentgateway. Two resources need to exist for the dashboard to populate:

1. An `EnterpriseAgentgatewayPolicy` attached to the Gateway you want traced, with both `tracing` and `accessLog` configured to ship to the collector, **and** with the right CEL attributes so MCP tool names, LLM model names, and token counts land in ClickHouse.
2. A `ReferenceGrant` in the `kagent` namespace allowing cross-namespace reference to the collector Service.

The policy below is the one actually attached to `mcp-gateway` in the demo cluster. It captures:
- **MCP attributes** for the `Tool Requests` dashboard panel (`gen_ai.tool.name`, `mcp.tool_name`, `mcp.tool_target`, `mcp.method_name`, `mcp.session_id`).
- **LLM attributes** for the `Token Usage By Model` and `Tokens Used` panels (`llm.provider`, `llm.request_model`, `llm.response_model`, `llm.input_tokens`, `llm.output_tokens`, `llm.total_tokens`).
- **HTTP attributes** for the `Requests Over Time` and `Errors Over Time` panels (status codes, paths — these come from access log defaults).

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-gateway-tracing
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: mcp-gateway
  frontend:
    tracing:
      backendRef:
        group: ""
        kind: Service
        name: solo-enterprise-telemetry-collector
        namespace: kagent
        port: 4317
      protocol: GRPC
      clientSampling: "true"
      randomSampling: "true"
      resources:
        - { name: service.name,                 expression: '"mcp-gateway"' }
        - { name: deployment.environment.name,  expression: '"demo"' }
      attributes:
        add:
          - { name: request.host,        expression: 'request.host' }
          - { name: mcp.method_name,     expression: 'default(mcp.methodName, "")' }
          - { name: mcp.session_id,      expression: 'default(mcp.sessionId, "")' }
          - { name: mcp.tool_name,       expression: 'default(mcp.tool.name, "")' }
          - { name: backend.name,        expression: 'default(backend.name, "")' }
          - { name: llm.provider,        expression: 'default(llm.provider, "")' }
          - { name: llm.request_model,   expression: 'default(llm.requestModel, "")' }
          - { name: llm.response_model,  expression: 'default(llm.responseModel, "")' }
          - { name: llm.input_tokens,    expression: 'default(llm.inputTokens, 0)' }
          - { name: llm.output_tokens,   expression: 'default(llm.outputTokens, 0)' }
          - { name: llm.total_tokens,    expression: 'default(llm.totalTokens, 0)' }
    accessLog:
      otlp:
        backendRef:
          group: ""
          kind: Service
          name: solo-enterprise-telemetry-collector
          namespace: kagent
          port: 4317
        protocol: GRPC
      attributes:
        add:
          - { name: gen_ai.tool.name,    expression: 'default(mcp.tool.name, "")' }
          - { name: mcp.tool_name,       expression: 'default(mcp.tool.name, "")' }
          - { name: mcp.tool_target,     expression: 'default(mcp.tool.target, "")' }
          - { name: mcp.method_name,     expression: 'default(mcp.methodName, "")' }
          - { name: llm.provider,        expression: 'default(llm.provider, "")' }
          - { name: llm.request_model,   expression: 'default(llm.requestModel, "")' }
          - { name: llm.response_model,  expression: 'default(llm.responseModel, "")' }
          - { name: llm.input_tokens,    expression: 'default(llm.inputTokens, 0)' }
          - { name: llm.output_tokens,   expression: 'default(llm.outputTokens, 0)' }
          - { name: llm.total_tokens,    expression: 'default(llm.totalTokens, 0)' }
---
# In the kagent namespace — allow the agentgateway-system policy above to
# reference the telemetry collector Service across namespaces.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-agentgateway-otel-access
  namespace: kagent
spec:
  from:
    - { group: enterpriseagentgateway.solo.io, kind: EnterpriseAgentgatewayPolicy, namespace: agentgateway-system }
  to:
    - { group: "", kind: Service, name: solo-enterprise-telemetry-collector }
```

**Important:** the `llm.*` attributes only populate when traffic flows through an **AI-type backend** (`spec.ai.provider.*` on the backend). If traffic instead flows through a plain `Service` backend (e.g. an in-cluster LLM proxy), agentgateway has no way to parse the request as an LLM call and these attributes stay empty — leaving the `Tokens Used` and `Token Usage By Model` panels showing zero. For the dashboard to populate fully, route LLM traffic to an AI backend (Anthropic, OpenAI, etc.) on the same gateway this policy targets.

If you target a different Gateway, change `spec.targetRefs[0].name`, the `service.name` resource expression, and the policy `metadata.name` to match.

## MCP Tool Selection

1. Create a gateway for the MCP server you deployed
```
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mcp-gateway
  namespace: agentgateway-system
  labels:
    app: github-mcp-server
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: mcp
      port: 3000
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
```

2. Create a Kubernetes `Secret` holding your GitHub PAT. The value must be the full `Authorization` header (prefixed with `Bearer `), stored under the key `Authorization` — agentgateway uses this value verbatim as the header on upstream requests.

```
export GITHUB_PAT=

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-pat
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: "Bearer ${GITHUB_PAT}"
EOF
```

3. Deploy a backend so the gateway knows what to route to. In this case, its the github copilot MCP server
```
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: github-mcp-server
  namespace: agentgateway-system
spec:
  entMcp:
    toolMode: Standard
    targets:
      - name: github-copilot
        static:
          host: api.githubcopilot.com
          port: 443
          path: /mcp/
          protocol: StreamableHTTP
          policies:
            tls: {}
            auth:
              secretRef:
                name: github-pat
EOF
```


4. Add a Kubernetes Secret holding your Anthropic API key.

```
export ANTHROPIC_API_KEY=

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: anthropic-api-key
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: "Bearer ${ANTHROPIC_API_KEY}"
EOF
```

5. Create an `EnterpriseAgentgatewayBackend` of type `ai` for Anthropic.

```
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  labels:
    app: agentgateway-route
  name: anthropic
  namespace: agentgateway-system
spec:
  ai:
    provider:
      anthropic:
        model: "claude-sonnet-4-6"
  policies:
    ai:
      # store model internal state instead of re-tokenzing for a prompt
      promptCaching: {}
    auth:
      secretRef:
        name: anthropic-api-key
EOF
```

6. Create the `HTTPRoute` to route by path.

```
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route
  namespace: agentgateway-system
  labels:
    app: github-mcp-server
spec:
  parentRefs:
    - name: mcp-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /anthropic
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplaceFullPath
              replaceFullPath: /v1/chat/completions
      backendRefs:
        - name: anthropic
          namespace: agentgateway-system
          group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: github-mcp-server
          namespace: agentgateway-system
          group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
EOF
```

### Test Connectivity

Capture the IP of the gateway
```
export GATEWAY_IP=$(kubectl get svc mcp-gateway -n agentgateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $GATEWAY_IP
```

**To test LLM traffic**

Anthropic's Messages API requires `model`, `max_tokens`, and a `messages` array. The system prompt belongs at the top level (not inside `messages`). Do **not** set the `x-api-key` or `Authorization` header here — the gateway injects it from the `anthropic-api-key` Secret.

```
curl "http://$GATEWAY_IP:3000/anthropic" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "system": "You are a skilled cloud-native network engineer.",
    "messages": [
      {
        "role": "user",
        "content": "Write me a paragraph containing the best way to think about Istio Ambient Mesh"
      }
    ]
  }' | jq
```


**To test MCP**, open MCP Inspector
```
npx modelcontextprotocol/inspector#0.18.0
```

Specify, within the **URL** section, the following:
```
http://YOUR_ALB_IP:3000/mcp
```

With progressive disclosure, On `tools/list` you should see only `get_tool` and `invoke_tool` instead of the full GitHub MCP tool set. Call `get_tool` with e.g. `{"name": "list_issues"}` to fetch a specific tool's schema, then `invoke_tool` to execute it.

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
      openai: {} # model taken from request
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
            value: /v1
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
        name: openai-api-key
```

**6. Copilot SDK pointed at the gateway, NOT at OpenAI:**

```bash
# Resolve the gateway's external IP first so the config file is ready to use.
export GW_IP=$(kubectl get gateway byok-gateway -n agentgateway-system \
  -o jsonpath='{.status.addresses[0].value}')

cat > copilot-sdk.config.json <<EOF
{
  "providers": {
    "openai": {
      "baseURL": "http://${GW_IP}/v1",
      "apiKey":  "sdk-to-gateway-token"
    }
  }
}
EOF
```

The `apiKey` here is what the SDK presents to **agentgateway** — not the OpenAI key. It can be an internal JWT, an API key stored in a `Secret`, or omitted entirely if you're using mTLS between the SDK and the gateway.

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

The canonical pattern in this stack is **IdP-driven OBO**: kagent passes the user's raw OIDC/IdP access token through to agentgateway, and **agentgateway's STS performs the token exchange against the IdP** before forwarding to the downstream backend. kagent does not mint OBO tokens itself in this configuration (`SKIP_OBO=true`); the IdP is the sole minter of identity and the STS is the sole exchanger.

```
┌──────────┐  1. Login (OIDC PKCE)        ┌────────────────┐
│  User    │ ───────────────────────────▶ │     IdP        │
│ (Alice)  │ ◀─────────────────────────── │ (Entra today)  │
└────┬─────┘  user access token (sub=alice)└────────────────┘
     │
     │  2. user token in Authorization
     ▼
┌────────────────┐
│   kagent UI    │  SKIP_OBO=true → forwards raw user token
│   + runtime    │
└────────┬───────┘
         │  3. user token in Authorization
         │     (KAGENT_PROPAGATE_TOKEN=true on the Agent)
         ▼
┌─────────────────────────────────────────────────────────────┐
│                       agentgateway                          │
│                                                             │
│  dataplane ──── STS_URI ────▶  STS (port 7777)              │
│    │                              │                         │
│    │                              │  4. POST /token         │
│    │                              │     (grant_type=        │
│    │                              │      jwt-bearer)        │
│    │                              ▼                         │
│    │                          ┌────────┐                    │
│    │                          │  IdP   │  5. exchanged      │
│    │                          │ /token │     token scoped   │
│    │                          └────────┘     to downstream  │
│    │                              │                         │
│    │     ◀──────────────────────  │                         │
│    │   exchanged token (sub=user, aud=downstream client)    │
│    │                                                        │
└────┼────────────────────────────────────────────────────────┘
     │  6. exchanged token in Authorization
     ▼
┌────────────────┐    7. provider-native auth (API key)
│ llm-obo-proxy  │ ──────────────────────────▶  Anthropic / OpenAI
│  (validates    │
│  exchanged     │
│  token)        │
└────────────────┘
```

**Key properties to point at on stage:**

- kagent never mints its own JWT in this topology. The IdP's token flows untouched through kagent and through the agent.
- The STS lives inside the agentgateway controller pod (`enterprise-agentgateway` Deployment, port 7777). The dataplane pod calls it via `STS_URI` injected from `EnterpriseAgentgatewayParameters`.
- The exchange call is **agentgateway → IdP /token endpoint**, not agentgateway → some internal mint. For Entra it's `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` (Microsoft's flavor); for an RFC 8693-compliant IdP it's `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`.
- The exchanged token is what the downstream backend validates. The proxy validates the IdP-issued exchanged token, not anything agentgateway issued itself. In some cases, it may be a k8s Service because due to some changes with LLM providers (e.g - Anthropic), they don't want you using "third-party", so the request gets blocked on the LLM providers end.


### OBO Flow demo: kagent + Entra

kagent + entra for OBO flow. If you're using another OIDC/iDP provider, please note that the overall concepts are the same. Its just a matter of having a different issuer.

To configure OBO, you can use the following as an example if you want to use Entra: https://github.com/AdminTurnedDevOps/agentic-demo-repo/blob/main/kagent-enterprise/obo/setup.md

#### What's wired up right now

If you followed the Entra guide above in the **OBO Flow Demo: kagent + Entra** section, your "state of the world" will look like the below:

```bash
# 1. kagent is configured with Entra OIDC and SKIP_OBO=true
kubectl get configmap kagent-enterprise-config -n kagent -o yaml \
  | grep -E "OIDC_ISSUER|OIDC_CLIENT_ID|OBO_CLAIMS_TO_PROPAGATE|SKIP_OBO"

# Expected:
#   OIDC_ISSUER:             https://login.microsoftonline.com/<TENANT_ID>/v2.0
#   OIDC_CLIENT_ID:          <KAGENT_BACKEND_CLIENT_ID>
#   OBO_CLAIMS_TO_PROPAGATE: email,groups,oid,tid,upn
#   SKIP_OBO:                "true"

# 2. The demo agent has KAGENT_PROPAGATE_TOKEN=true
kubectl get deploy obo-demo-agent -n kagent \
  -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="KAGENT_PROPAGATE_TOKEN")]}{.name}={.value}{"\n"}{end}'
# KAGENT_PROPAGATE_TOKEN=true

# 3. The agentgateway STS is configured with Entra as the subject validator,
#    and the dataplane has STS_URI/STS_AUTH_TOKEN injected.
kubectl get enterpriseagentgatewayparameters agentgateway-entra-testing-enterprise \
  -n agentgateway-system -o jsonpath='{.spec.env}' | jq .
# [
#   { "name": "STS_URI",        "value": "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/token" },
#   { "name": "STS_AUTH_TOKEN", "value": "/var/run/secrets/xds-tokens/xds-token" }
# ]

# 4. The per-backend OBO exchange policy targets the llm-obo-proxy Service.
kubectl get enterpriseagentgatewaypolicy entra-obo-token-exchange \
  -n agentgateway-system -o yaml | sed -n '/spec:/,/status:/p'
# spec:
#   backend:
#     tokenExchange:
#       entra:
#         tenantId:  <TENANT_ID>
#         clientId:  <KAGENT_BACKEND_CLIENT_ID>
#         scope:     api://<KAGENT_BACKEND_CLIENT_ID>/kagent-backend
#         clientSecretRef: { key: client_secret, name: entra-obo-client-secret }
#       mode: ExchangeOnly
#   targetRefs:
#     - { group: "", kind: Service, name: llm-obo-proxy }
```

These four resources are the whole OBO control surface. Everything else (Gateway, HTTPRoute, llm-obo-proxy Deployment) is plain Kubernetes plumbing.

#### Evidence the chain is working

After driving a request through the kagent UI to the `obo-demo-agent`, you can confirm each hop:

```bash
kubectl logs deployment/enterprise-agentgateway -n agentgateway-system \
  | grep '"path":"/token"' | tail -5
# {"…","method":"POST","path":"/token","status_code":200,…}

kubectl logs deployment/llm-obo-proxy -n agentgateway-system \
  | grep -v healthz | tail -6
# INFO:llm-obo-proxy:validated token for oid=<USER_OID> aud=<KAGENT_BACKEND_CLIENT_ID> scp=kagent-backend
# INFO:httpx:HTTP Request: POST https://api.anthropic.com/v1/messages "HTTP/1.1 200 OK"
```

What this tells you concretely:

- **`oid=<USER_OID>`**: The human user's Entra object ID is present in the token the proxy validates. The user's identity made it all the way to the downstream proxy.
- **`aud=<KAGENT_BACKEND_CLIENT_ID>` + `scp=kagent-backend`**: This is an **Entra-issued** token, scoped to the `kagent-backend` app registration. agentgateway did call Entra's `/token` endpoint and received back a fresh, audience-restricted token. The proxy refuses to accept tokens with the wrong audience.
- **The next log line is `POST https://api.anthropic.com/v1/messages 200`**: Only after the OBO token validates does the proxy call Anthropic with the provider API key. No identity, no call.

#### The four CRDs that make this work

(Full YAML in `setup.md` via the **OBO Flow Demo: kagent + Entra** section; these are the headline shapes.)

**a. Helm values for the agentgateway controller — turns on the STS:**

```yaml
tokenExchange:
  enabled: true
  issuer: "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
  subjectValidator:
    validatorType: "remote"
    remoteConfig:
      url: "https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys"
  apiValidator:   { validatorType: "k8s" }
  actorValidator: { validatorType: "k8s" }
```

**b. `EnterpriseAgentgatewayParameters` — passes STS endpoint to the dataplane:**

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata: { name: agentgateway-entra-testing-enterprise, namespace: agentgateway-system }
spec:
  env:
    - { name: STS_URI,        value: "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/token" }
    - { name: STS_AUTH_TOKEN, value: "/var/run/secrets/xds-tokens/xds-token" }
```

The `Gateway` references this via `spec.infrastructure.parametersRef`.

**c. `EnterpriseAgentgatewayPolicy` — declares "do an Entra OBO exchange before calling this backend":**

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: { name: entra-obo-token-exchange, namespace: agentgateway-system }
spec:
  targetRefs:
    - { kind: Service, name: llm-obo-proxy, group: "" }
  backend:
    tokenExchange:
      mode: ExchangeOnly
      entra:
        tenantId: "${TENANT_ID}"
        clientId: "${KAGENT_BACKEND_CLIENT_ID}"
        scope:    "api://${KAGENT_BACKEND_CLIENT_ID}/kagent-backend"
        clientSecretRef: { name: entra-obo-client-secret, key: client_secret }
```

This is the field that triggers the agentgateway → Entra `/token` call. **It is Entra-specific** — see "Adapting to Keycloak" below.

**d. The kagent `Agent` — `KAGENT_PROPAGATE_TOKEN=true`:**

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: obo-demo-agent, namespace: kagent }
spec:
  type: Declarative
  declarative:
    modelConfig: anthropic-model-config         # baseUrl points at agentgateway /llm route
    deployment:
      env:
        - { name: KAGENT_PROPAGATE_TOKEN, value: "true" }
```

Without this env var, kagent will not forward the user's Entra access token to the agent, so the STS has nothing to exchange and the whole chain breaks. Demo-killer config bug; worth memorising.

### Agent Identity With OBO

"if it's this agent identity, only allow these MCP server tools."

The mechanism is `backend.mcp.authorization` on an `EnterpriseAgentgatewayPolicy`, evaluating CEL expressions that gate `mcp.tool.name` on whichever signal carries agent identity. In the running Entra OBO setup, that signal is an `X-Agent-Name` HTTP header (see the next subsection for why the OBO token doesn't carry an `act` claim). `jwt.sub` is also available if you want to gate on user identity. With one or more `Allow` rules present, the policy becomes **deny-by-default** and every other tool is invisible to the agent.

**Example:**

```yaml
matchExpressions:
  - 'request.headers["x-agent-name"] == "obo-readonly-agent" && mcp.tool.name.startsWith("search_")'
```

Different `X-Agent-Name` values get different visible toolsets — same backend, same MCP server, per-agent enforcement. The killer feature: **`list_tools` filters per-item**, so `obo-readonly-agent` doesn't even *see* the tools it can't call; it never has to attempt a forbidden call and get a 403.

#### OBO Agent/tool isolation for MCP

Prerequisite:
1. `mcp-gateway` in the **MCP Tool Selection** section is deployed
2. `mcp-gateway` must reference the STS parameters

The Gateway that fronts the MCP backend needs `infrastructure.parametersRef` so the dataplane behind it receives `STS_URI` and `STS_AUTH_TOKEN`. Without this, OBO can't work on routes attached to this Gateway. Pointing at the same `EnterpriseAgentgatewayParameters` used by the LLM-proxy demo is the simplest path:

```yaml
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mcp-gateway
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: agentgateway-entra-testing-enterprise
  listeners:
    - name: mcp
      port: 3000
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
```

##### `RemoteMCPServer` — single resource referenced by both agents

```yaml
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: github-mcp-via-gateway
  namespace: kagent
spec:
  description: "GitHub Copilot MCP server accessed via agentgateway (mcp-gateway)"
  protocol: STREAMABLE_HTTP
  url: http://mcp-gateway.agentgateway-system.svc.cluster.local:3000/mcp
```

##### Two agents — same MCP server, different `X-Agent-Name`

```yaml
kubectl apply -f - <<EOF
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: obo-demo-agent, namespace: kagent }
spec:
  description: Full-access agent (gateway RBAC blocks merge/delete/secret-scan)
  type: Declarative
  declarative:
    modelConfig: anthropic-model-config
    deployment:
      env:
        - { name: KAGENT_PROPAGATE_TOKEN, value: "true" }
    systemMessage: |
      You can use GitHub MCP tools to manage issues, pull requests, and code.
      You cannot merge PRs, delete files, or run secret scans.
    tools:
      - type: McpServer
        mcpServer:
          name: github-mcp-via-gateway
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames: [ <all 46 GitHub MCP tool names — populate via `tools/list`> ]
        headersFrom:
          - { name: X-Agent-Name, value: obo-demo-agent }
---
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: obo-readonly-agent, namespace: kagent }
spec:
  description: Read-only agent (gateway RBAC restricts to search/list/get/read)
  type: Declarative
  declarative:
    modelConfig: anthropic-model-config
    deployment:
      env:
        - { name: KAGENT_PROPAGATE_TOKEN, value: "true" }
    systemMessage: |
      You are a read-only research assistant. Search, list, and read only.
    tools:
      - type: McpServer
        mcpServer:
          name: github-mcp-via-gateway
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames: [ <same 46-tool list> ]
        headersFrom:
          - { name: X-Agent-Name, value: obo-readonly-agent }
EOF
```

`toolNames` is required by kagent as it's the upper bound the agent runtime exposes to the LLM. Both agents list ALL 46 tools so the gateway is the sole filter. When each agent calls `tools/list` through the gateway, the gateway's CEL RBAC filters per-item and the LLM only learns about the tools that pass.

Capture the live tool list once and reuse. First grab the gateway IP (re-used by every `curl` below in this section):

```bash
export GW_IP=$(kubectl get svc mcp-gateway -n agentgateway-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway: http://${GW_IP}:3000/mcp"
```

Then run the MCP init dance and list the tools. All three curls include `X-Agent-Name: obo-demo-agent` so the recipe works whether or not the RBAC policy below has been applied — without that header, the deny-by-default policy returns an empty tool list and `jq` prints nothing.

```bash
SID=$(curl -sS -i -X POST "http://${GW_IP}:3000/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'X-Agent-Name: obo-demo-agent' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
  | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')

curl -sS -X POST "http://${GW_IP}:3000/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'X-Agent-Name: obo-demo-agent' \
  -H "mcp-session-id: ${SID}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

curl -sS -X POST "http://${GW_IP}:3000/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'X-Agent-Name: obo-demo-agent' \
  -H "mcp-session-id: ${SID}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | sed 's/^data: //' \
  | jq -r '.result.tools[].name'
```

Once the RBAC policy below is applied, this returns **43 of the 46 tools**. The three tools blocked from `obo-demo-agent` (`merge_pull_request`, `delete_file`, `run_secret_scanning`) need to be added to `toolNames` manually. If you run this recipe **before** applying the RBAC policy, you'll get all 46 in one go.

##### The RBAC policy: CEL gates `mcp.tool.name` on `X-Agent-Name`

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: github-mcp-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: github-mcp-server
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            # Read-only persona — search/get/list + dedicated *_read tools
            - 'request.headers["x-agent-name"] == "obo-readonly-agent" && (mcp.tool.name.startsWith("search_") || mcp.tool.name.startsWith("get_") || mcp.tool.name.startsWith("list_") || mcp.tool.name in ["issue_read", "pull_request_read"])'
            # Full persona — everything EXCEPT destructive/admin tools
            - 'request.headers["x-agent-name"] == "obo-demo-agent" && !(mcp.tool.name in ["merge_pull_request", "delete_file", "run_secret_scanning"])'
```

With at least one `Allow` rule present, the policy is deny-by-default, so any request whose `X-Agent-Name` doesn't match a rule sees zero tools and gets zero authorizations.

##### Testing: per-agent tool isolation

The fastest, most visual way to show this off is MCP Inspector — change the `X-Agent-Name` header in the UI and watch the visible tool list shrink and grow in real time. A scripted curl version follows for automation.

Capture the gateway IP first (reused by both demos below):

```bash
export GW_IP=$(kubectl get svc mcp-gateway -n agentgateway-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway: http://${GW_IP}:3000/mcp"
```

###### Visual demo: MCP Inspector

1. Open Inspector:
   ```bash
   npx modelcontextprotocol/inspector#0.18.0
   ```
2. Configure the connection:
   - **URL**: `http://${GW_IP}:3000/mcp`
   - **Transport**: Streamable HTTP
   - **Custom header**: `X-Agent-Name` = `obo-demo-agent`
3. Click **Connect**, then **List Tools** — 43 tools appear. `merge_pull_request`, `delete_file`, and `run_secret_scanning` are *not* in the list.
4. **Disconnect**, change the header value to `obo-readonly-agent`, **Reconnect**, **List Tools** — list shrinks to 26 tools (search/get/list/read only).
5. **Disconnect**, remove the `X-Agent-Name` header entirely, **Reconnect**, **List Tools** — empty list. Deny-by-default.

###### Scriptable verification (curl)

Same flow, no UI. Prints one line per persona — counts only, no tool dumps:

```bash
for name in obo-readonly-agent obo-demo-agent ""; do
  header=()
  [[ -n "$name" ]] && header=(-H "X-Agent-Name: ${name}")

  SID=$(curl -sS -i -X POST "http://${GW_IP}:3000/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "${header[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
    | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')
  curl -sS -X POST "http://${GW_IP}:3000/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "${header[@]}" \
    -H "mcp-session-id: ${SID}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  count=$(curl -sS -X POST "http://${GW_IP}:3000/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "${header[@]}" \
    -H "mcp-session-id: ${SID}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | sed 's/^data: //' | jq '.result.tools | length')
  printf "X-Agent-Name=%-22s → %d tools\n" "${name:-(none)}" "$count"
done
```

Output:

```
X-Agent-Name=obo-readonly-agent  → 26 tools
X-Agent-Name=obo-demo-agent      → 43 tools
X-Agent-Name=(none)              →  0 tools
```

## Intent-Based Routing

Intent-based routing lets agentgateway decide *which* LLM model serves a given request — based on the user, the agent, the prompt size, or the workload type — without the caller having to choose. The Copilot SDK (or kagent agent) requests a stable model name like `"default"`, and agentgateway resolves it to a concrete model per request.

### What's available at request transformation time (verified)

CEL transformations on the `model` field run **before** the upstream LLM call. The CEL context at that point includes:

- `llm.requestModel` — what the client asked for
- `llm.provider` — the resolved provider
- `request.headers[...]` — any client-provided header
- `request.body` — the raw request body (use `size(request.body)` for payload-size estimation)
- `llm.prompt` — the parsed prompt content, **only** if prompt-capture is enabled elsewhere (prompt guard, logging); otherwise `None`
- JWT claims — `jwt.sub`, `jwt.aud`, `jwt.azp`, `jwt.claims.*` — present whenever JWT auth runs first. **Note:** in the running Entra OBO setup the token has no `act` claim; agent identity is conveyed via `X-Agent-Name` header instead (see the OBO MCP isolation section)



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

          // Agent-based: the read-only agent gets the cheap model;
          // the full-access agent (generation-heavy) gets the strong one.
          // Uses the same X-Agent-Name header as the OBO MCP isolation demo.
          : request.headers["x-agent-name"] == "obo-demo-agent"
            ? "claude-sonnet-4-6"
          : request.headers["x-agent-name"] == "obo-readonly-agent"
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

Outcome:
1. **Same client request, different model.** Two `curl`s to the same endpoint with the same body, differing only in `x-user-tier: premium` → response model differs. Show the model name in the response.
2. **Agent identity drives routing.** Same user, two agents in OBO flow → `obo-readonly-agent` gets the cheap model, `obo-demo-agent` gets the strong one. Token cost difference visible in logs/metrics.
3. **Payload size flip.** Short prompt → cheap model. Long prompt (paste a wall of text) → strong model.
4. **Aliases hide the providers.** Client only ever sees `default`, `smart`, `local`. Swap the underlying concrete models in the YAML — no client change.



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
- **Compliance traceability.** Every request through the gateway is logged with user (`jwt.oid` / `jwt.preferred_username`), agent (`X-Agent-Name`), chosen model, provider, token counts.