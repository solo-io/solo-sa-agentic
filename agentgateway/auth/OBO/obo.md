## 12. OBO

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