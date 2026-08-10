# MCP ExtMCP Guardrails Demo

A runnable Enterprise Agentgateway demo for **MCP-aware external guardrails**
(`mcpGuardrails` / **ExtMCP**), introduced in
[agentgateway#1842](https://github.com/agentgateway/agentgateway/pull/1842).

ExtMCP is a backend policy modeled on Envoy `ext_authz`, but at the **MCP method
layer**: a remote gRPC server can **gate or mutate individual JSON-RPC methods**
(`tools/call`, `tools/list`, `prompts/get`, …) without re-implementing MCP
framing. The callout is opt-in per method and runs post-auth.

Like the other demos in this repo, this uses **mock services** so the gateway
behavior can be tested locally with no external dependencies.

## 1. Quick Start

1. Set your Enterprise Agentgateway license key:

   ```bash
   export AGENTGATEWAY_LICENSE_KEY='<license-key>'
   ```

2. Install a clean kind cluster with Enterprise Agentgateway and the demo:

   ```bash
   make install
   ```

3. Check installed resources:

   ```bash
   make status
   ```

4. Port-forward the MCP gateway listener (leave running in a second terminal):

   ```bash
   make port-forward
   # MCP endpoint -> http://localhost:18083/mcp   (Host: mcp.example.com)
   ```

5. Run the use cases below.

6. Remove the demo cluster:

   ```bash
   make cleanup
   ```

## 2. What Gets Installed

1. Enterprise Agentgateway (`enterprise-agentgateway`, **v2026.6.3** — `mcpGuardrails`
   needs v2026.6.x+) in the `agentgateway-system` namespace.
2. **`demo-mcp`** — a mock MCP server (StreamableHTTP) exposing two tools:
   `echo` (benign) and `forbidden_action` (a "dangerous" tool).
3. **`ext-mcp`** — the ExtMCP guardrail policy server (a gRPC server). It **denies
   any `tools/call` whose tool name contains `forbidden`** and **appends
   ` [extmcp]` to every tool description on `tools/list`**. This mirrors the
   behavior of agentgateway's own e2e test server
   (`controller/hack/testbox/extmcp.go`).
4. A Gateway (`mcp-ext-guardrails-gateway`, MCP listener on `:3000`), an
   `AgentgatewayBackend` + `HTTPRoute` (`mcp.example.com`) fronting `demo-mcp`.
5. The **`mcp-guardrails`** `EnterpriseAgentgatewayPolicy` wiring the backend to `ext-mcp`
   (`tools/call: Request`, `tools/list: Response`, `failureMode: FailClosed`).

## 3. Use Cases

All calls go through the port-forward with the `Host: mcp.example.com` header.
Set up a session first:

```bash
BASE=http://localhost:18083/mcp
HDRS=(-H 'Host: mcp.example.com' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

# initialize and capture the session id
SID=$(curl -s -D - -o /dev/null "$BASE" "${HDRS[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' \
  | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')
curl -s "$BASE" "${HDRS[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
```

### 3.1 Response mutation — `tools/list`

```bash
curl -s "$BASE" "${HDRS[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

Every tool description ends with **` [extmcp]`** — proof the guardrail server
rewrote the response:

```
"echo" ... "description":"Echo back the provided message. [extmcp]"
"forbidden_action" ... "description":"A dangerous tool that the ExtMCP guardrail blocks. [extmcp]"
```

### 3.2 Request denial — `tools/call` on a forbidden tool

```bash
curl -s "$BASE" "${HDRS[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"forbidden_action","arguments":{}}}'
```

Blocked by the guardrail before it reaches `demo-mcp`:

```json
{"jsonrpc":"2.0","id":3,"error":{"code":-32001,"message":"tool forbidden_action is not allowed"}}
```

### 3.3 Pass-through — `tools/call` on a benign tool

```bash
curl -s "$BASE" "${HDRS[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"}}}'
```

```json
{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"echo: hi"}]}}
```

You can watch the callouts from the guardrail server:

```bash
kubectl -n agentgateway-system logs deploy/ext-mcp -f
# [ext-mcp][response] MUTATE tools/list (2 tools)
# [ext-mcp][request] DENY tools/call name=forbidden_action
# [ext-mcp][request] PASS method=tools/call ...
```

> Prefer a GUI? Run `npx @modelcontextprotocol/inspector`, choose transport
> **Streamable HTTP**, connect to `http://localhost:18083/mcp` (no custom headers
> needed — the route also accepts the `localhost` hostname), then **List Tools**
> (see the `[extmcp]` suffixes), run `echo` (passes), and run `forbidden_action`
> (denied). Note: Inspector's HTTP client overrides the `Host` header from the URL,
> which is why the route accepts `localhost` in addition to `mcp.example.com`.

## 4. How It Works

The `mcp-guardrails` policy attaches to the MCP `AgentgatewayBackend` and, per
method, calls the ExtMCP server over gRPC:

```yaml
backend:
  mcp:
    guardrails:
      processors:
      - remote:
          backendRef: {name: ext-mcp, port: 9001}
          failureMode: FailClosed      # policy server down => MCP blocked
        methods:
          tools/call: Request           # CheckRequest -> may deny/mutate params
          tools/list: Response          # CheckResponse -> may mutate the result
```

The gRPC contract is agentgateway's bespoke `ExtMcp` service
(`agentgateway.dev.ext_mcp`, `CheckRequest`/`CheckResponse`) — **not** Envoy
`ext_authz` — so a generic ext_authz server won't work.

## 5. Notes

- **CRDs**: the MCP backend is a base `agentgateway.dev/AgentgatewayBackend`
  (`spec.mcp`), and the guardrails policy is an `EnterpriseAgentgatewayPolicy`
  (matching this repo's `enterprise-mcp` demo). Both the enterprise and base
  policy CRDs expose the identical `backend.mcp.guardrails` field, so
  `agentgateway.dev/AgentgatewayPolicy` (as used in PR #1842's own testdata)
  works interchangeably.
- **`ext-mcp` server**: shipped the repo's "stock public image + inline code" way
  (`python:3.12-slim`, `pip install grpcio`, generate stubs from the inlined
  `ext_mcp.proto` at start). It's a small re-implementation of the deny/mutate
  logic from agentgateway's Apache-2.0 e2e testbox, not a published image.
- **h2c**: the `ext-mcp` Service is marked `appProtocol: kubernetes.io/h2c` for
  the plaintext gRPC callout.
