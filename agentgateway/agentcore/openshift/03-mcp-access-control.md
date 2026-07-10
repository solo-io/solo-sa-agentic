## MCP tool access control: identity, RBAC & ABAC (optional extension)

If the agent also reaches out to MCP servers through AgentGateway, the gateway can authorize MCP tools three ways, all on the same CEL engine: per **user** (Okta `jwt.*` claims), per **agent identity** (an `X-Agent-Name` header — RBAC/tool isolation), and per **request attributes** (ABAC). Define an MCP backend and route, then attach `EnterpriseAgentgatewayPolicy` authorization rules.

```yaml
oc apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: public-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
      - name: deepwiki
        static:
          host: mcp.deepwiki.com
          port: 443
          policies:
            tls: {}
      - name: microsoft
        static:
          host: learn.microsoft.com
          port: 443
          path: /api/mcp
          policies:
            tls: {}
EOF
```

Expose it on a route:

```yaml
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: public-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /public/mcp
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: public-mcp-backend
EOF
```

The gateway's CEL authorization engine gates every `tools/list` **and** `tools/call` per request. Two CEL attributes matter most here, and the difference is easy to get wrong:

- `mcp.tool.target` — the **backend/server** the tool came from (`deepwiki`, `microsoft`).
- `mcp.tool.name` — the tool's **own, unprefixed** name (`ask_question`, `read_wiki_structure`). `tools/list` displays the two joined as `<target>_<name>` (e.g. `deepwiki_ask_question`), but CEL matches on the unprefixed `mcp.tool.name`.

**To gate on `jwt.*` you must validate the token on this route** — `jwt.*` is only populated when a `jwtAuthentication` policy runs on `/public/mcp`. The Step 3d policy targets `agentcore-route`, **not** this one, so add a JWT policy for the MCP route (without it, `jwt.sub`-based rules evaluate against empty claims and silently match nothing):

```yaml
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: public-mcp-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: public-mcp
      group: gateway.networking.k8s.io
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: ${OKTA_ISSUER}
          audiences:
            - "${AGENTCORE_AUDIENCE}"
          jwks:
            remote:
              jwksPath: /oauth2/default/v1/keys
              backendRef:
                name: okta-jwks
                kind: AgentgatewayBackend
                group: agentgateway.dev
EOF
```

With that in place, gate tools per user off the validated Okta claims:

```yaml
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-tool-access
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: public-mcp-backend
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - 'jwt.sub == "alice@example.com" && mcp.tool.target == "deepwiki"'
            - 'jwt.sub == "bob@example.com" && mcp.tool.name == "microsoft_docs_search"'
EOF
```

> Apply `public-mcp-jwt` **only if** you use the `jwt.*` rules (this per-user example and the `Deny`-contractor rule) — it's what populates `jwt.*`. The `X-Agent-Name` RBAC and `x-change-ticket` ABAC examples below key off **headers** and work without it. Note the trade-off: because it's `mode: Strict`, once applied it makes **every** `/public/mcp` request (including the header-only demos) require a valid Okta token. To keep those demos token-free, skip `public-mcp-jwt`; to run per-user `jwt.sub` rules, apply it and send a token on all calls.

### Agent identity & tool isolation (RBAC via `X-Agent-Name`)

When several AgentCore agents share one MCP backend, isolate their tools by **agent identity** rather than user. The agent identifies itself with an `X-Agent-Name` header on its MCP calls, and a CEL policy gates `mcp.tool.*` on that header. Set the header where the agent builds its MCP client — in the scaffold's `myagent/app/myagent/mcp_client/client.py`:

```python
import os
from mcp.client.streamable_http import streamablehttp_client
from strands.tools.mcp.mcp_client import MCPClient

AGENT_NAME = os.environ.get("AGENT_NAME", "research-agent")
MCP_URL = "http://<AGW_LB>:8080/public/mcp"   # the gateway MCP route

def get_streamable_http_mcp_client() -> MCPClient:
    return MCPClient(lambda: streamablehttp_client(
        MCP_URL, headers={"X-Agent-Name": AGENT_NAME}))
```

Then gate tools on that header. With at least one `Allow` rule present the policy is **deny-by-default** — a request whose `X-Agent-Name` matches no rule sees zero tools:

```yaml
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-agent-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: public-mcp-backend
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - 'request.headers["x-agent-name"] == "research-agent" && mcp.tool.target == "deepwiki"'
            - 'request.headers["x-agent-name"] == "docs-agent" && mcp.tool.name.startsWith("microsoft_")'
EOF
```

### ABAC with CEL (per-request attributes)

RBAC answers *which tools may this agent ever call?* **ABAC** answers *may this specific request happen, given the attributes it carries right now?* The same CEL engine is a full attribute-based decision point over subject (`jwt.*`), resource (`mcp.tool.*`), action (`mcp.methodName`, `request.method`), and environment (`request.headers`, `source.address`). The three actions compose:

1. any matching **`Deny`** denies the request;
2. every **`Require`** rule must match (deny-by-default);
3. if any **`Allow`** rule exists, at least one must match.

`Require`/`Deny` policies **merge** with the `Allow` policies above without editing them. Two attribute rules — an environment gate and a subject gate:

```yaml
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-abac-change-ticket
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: public-mcp-backend
  backend:
    mcp:
      authorization:
        action: Require
        policy:
          matchExpressions:
            # ask_question is only reachable with an approved change ticket.
            # A missing header fails CEL evaluation = no match, so Require denies.
            - 'mcp.tool.name != "ask_question" || request.headers["x-change-ticket"].startsWith("CHG-")'
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-abac-deny-contractors
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: public-mcp-backend
  backend:
    mcp:
      authorization:
        action: Deny            # deny overrides allow; needs JWT auth on the route to populate jwt.*
        policy:
          matchExpressions:
            - 'jwt.sub.startsWith("contractor-")'
EOF
```

You can drive any of this interactively with the MCP inspector (swap the header, watch the tool list change):

```bash
npx @modelcontextprotocol/inspector@0.21.2 \
  --cli "http://${AGW_LB}:8080/public/mcp" \
  --transport http \
  --method tools/list \
  --header "X-Agent-Name: research-agent" | jq '.tools[].name'
```

See the AgentGateway docs for [limiting MCP tool access](https://docs.solo.io/agentgateway/latest/mcp/tool-access/#limit-tool-access) and [validating JWTs on MCP routes](https://docs.solo.io/agentgateway/latest/mcp/mcp-access/#validate-jwt-tokens), and the [`enterprise-mcp`](../../enterprise-mcp/README.md) guide this pattern is drawn from.
