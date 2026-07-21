# Snowflake MCP server through AgentGateway

Snowflake hosts an MCP server per account that exposes your databases and Cortex services as MCP tools. This chapter routes the agent to that server **through** AgentGateway: the gateway holds the Snowflake credential (a Programmatic Access Token) so the agent never sees it, and — as in [`03-mcp-access-control.md`](03-mcp-access-control.md) — the same Okta identity that gates the runtime can gate the Snowflake tools.

The MCP route rides the existing `agentgateway-proxy` gateway on `:8080` (the only listener exposed on this cluster), so there is no new `Gateway` or load balancer to stand up — just a backend, a route, and policies.

### Prerequisites

- A Snowflake account with a **hosted MCP server** (Snowsight → the account's `mcp-servers` endpoint under a database/schema).
- A Snowflake **Programmatic Access Token (PAT)** for a role that can reach that MCP server.

Export the account's MCP endpoint so the manifests below stay generic:

```bash
export SNOWFLAKE_HOST="<account>.snowflakecomputing.com"
export SNOWFLAKE_MCP_PATH="/api/v2/databases/<DB>/schemas/<SCHEMA>/mcp-servers/<SERVER>"
```

### Store the PAT as a secret

The gateway authenticates to Snowflake with the PAT in the `Authorization` key of a secret. The agent and the caller never handle it.

```bash
export SNOWFLAKE_PAT="<your snowflake programmatic access token>"
oc create secret generic snowflake-pat -n agentgateway-system \
  --from-literal=Authorization="${SNOWFLAKE_PAT}" \
  --dry-run=client -o yaml | oc apply -f -
```

### MCP backend to Snowflake

An `EnterpriseAgentgatewayBackend` with an `mcp` target pointing at the Snowflake MCP endpoint. `tls.sni` must match the host (Snowflake requires SNI), and `auth.secretRef` attaches the PAT so the gateway adds it on the hop to Snowflake:

```bash
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: snowflake-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
      - name: snowflake
        static:
          host: ${SNOWFLAKE_HOST}
          port: 443
          path: ${SNOWFLAKE_MCP_PATH}
          protocol: StreamableHTTP
          policies:
            tls:
              sni: ${SNOWFLAKE_HOST}
            auth:
              secretRef:
                name: snowflake-pat
EOF
```

### Route on the existing gateway

Expose the backend at `/snowflake/mcp` on `agentgateway-proxy` (same pattern as `public-mcp` in doc 03 — no new `Gateway`, no path rewrite; the target path lives on the backend):

```bash
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: snowflake-mcp-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /snowflake/mcp
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: snowflake-mcp-backend
EOF
```

Confirm the route attached and resolved its backend:

```bash
oc get httproute snowflake-mcp-route -n agentgateway-system \
  -o jsonpath='{range .status.parents[*]}Accepted={.conditions[?(@.type=="Accepted")].status} ResolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}'
# Expect: Accepted=True ResolvedRefs=True
```

### Test the MCP server

List the Snowflake tools through the gateway with the MCP inspector (`${AGW_LB}` was exported in doc 01):

```bash
npx @modelcontextprotocol/inspector@0.21.2 \
  --cli "http://${AGW_LB}:8080/snowflake/mcp" \
  --transport http \
  --method tools/list | jq '.tools[].name'
```

At this point the route is **open** — anyone who can reach `:8080` can list and call the Snowflake tools. The next two sections lock it down.

### Gate the route with Okta

Validate the Okta token on the MCP route so only authenticated callers reach Snowflake, and so `jwt.*` claims are available to the tool policy below. This reuses the `okta-jwks` backend from doc 01; `mode: Strict` rejects a missing or invalid token:

```bash
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: snowflake-mcp-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: snowflake-mcp-route
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

Re-run the inspector with a bearer token (unauthenticated calls now get `401`):

```bash
npx @modelcontextprotocol/inspector@0.21.2 \
  --cli "http://${AGW_LB}:8080/snowflake/mcp" \
  --transport http --method tools/list \
  --header "Authorization: Bearer ${USER_TOKEN}" | jq '.tools[].name'
```

### Restrict which tools are exposed (RBAC)

The MCP authorization engine (the CEL rules covered in [`03-mcp-access-control.md`](03-mcp-access-control.md)) also applies to the Snowflake backend. Attach a policy to `snowflake-mcp-backend` to allow-list tools. With at least one `Allow` rule present, the policy is **deny-by-default** — any tool not matched is hidden from both `tools/list` and `tools/call`:

```bash
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: snowflake-mcp-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: snowflake-mcp-backend
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            # only this user may reach the Snowflake tools
            - 'jwt.sub == "analyst@example.com" && mcp.tool.target == "snowflake"'
EOF
```

`mcp.tool.target` is the target name (`snowflake`); `mcp.tool.name` is the tool's own unprefixed name. To confirm the engine is live, a rule that matches nothing — `matchExpressions: ['mcp.tool.name == ""']` — hides every tool (a fast smoke test that RBAC is enforced). See doc 03 for the full RBAC-by-agent-identity (`X-Agent-Name`) and ABAC (`Require`/`Deny`) patterns, which apply here unchanged.
