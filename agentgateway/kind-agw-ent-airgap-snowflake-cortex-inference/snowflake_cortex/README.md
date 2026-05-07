# Snowflake Cortex via AgentGateway

Route LLM requests through AGW Enterprise to Snowflake Cortex using the `openai` provider type with custom host/path overrides.

Snowflake Cortex exposes an **OpenAI-compatible** chat completions API:

```
POST https://<org>-<account>.snowflakecomputing.com/api/v2/cortex/v1/chat/completions
```

The request/response format is identical to OpenAI (model, messages, temperature, etc.), so AGW's `openai` provider handles it natively — we just override the host and path prefix.

## Architecture

```
Client → AGW Proxy (snowflake-cortex-gw:8080)
           │
           ├─ openai provider with custom host/pathPrefix
           ├─ transformation adds X-Snowflake-Authorization-Token-Type header
           │
           └─► https://<ORG>-<ACCOUNT>.snowflakecomputing.com/api/v2/cortex/v1/chat/completions
```

## Key CRD Fields

The `AgentgatewayBackend` uses these fields at the provider level to redirect the `openai` provider to Snowflake:

| Field | Value | Purpose |
|-------|-------|---------|
| `openai: {}` | empty | Tells AGW to use OpenAI request/response format |
| `host` | `<org>-<account>.snowflakecomputing.com` | Snowflake account endpoint |
| `port` | `443` | HTTPS |
| `pathPrefix` | `/api/v2/cortex/v1` | Replaces the default `/v1` prefix |
| `policies.tls: {}` | empty | Enables TLS to upstream |
| `policies.auth.secretRef` | secret with `Authorization: Bearer <PAT>` | Snowflake auth |
| `policies.transformation.request.add` | `X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN` | Required — without this, Snowflake treats PAT as OAuth and returns 390303 |

## Snowflake Account URL Format

The Snowflake UI URL `app.snowflake.com/<org>/<account>` maps to the REST API host as `<org>-<account>.snowflakecomputing.com`. For example:

- UI: `app.snowflake.com/<ORG>/<ACCOUNT>`
- REST API: `<ORG>-<ACCOUNT>.snowflakecomputing.com`

The format is `<org>-<account>` (NOT `<account>-<org>`).

## Snowflake Prerequisites

### 1. Create a Programmatic Access Token (PAT)

In the Snowflake UI:
- Go to your user menu (bottom-left) → **Settings** → **Programmatic Access Tokens**
- Click **Generate Token**, give it a name, set an expiry
- Copy the token value

### 2. Configure Network Policy (required for Cortex REST API)

Snowflake requires an **IP-based** network policy for Cortex REST API access. Without it, all requests return `390432: Network policy is required`.

```sql
USE ROLE ACCOUNTADMIN;

-- Allow specific IP (recommended for production)
CREATE NETWORK POLICY cortex_api_policy
  ALLOWED_IP_LIST = ('<YOUR_PUBLIC_IP>/32');

-- Or allow all IPs (for testing only)
CREATE NETWORK POLICY cortex_api_policy
  ALLOWED_IP_LIST = ('0.0.0.0/0');

ALTER ACCOUNT SET NETWORK_POLICY = cortex_api_policy;
```

**Important**: The policy must use `ALLOWED_IP_LIST` (legacy format), NOT `ALLOWED_NETWORK_RULE_LIST` (newer format). Cortex REST API does not recognize the network-rule-based policies.

**Important**: `CREATE NETWORK RULE` requires a database context — run `USE DATABASE SNOWFLAKE;` first if you see "no current database" errors.

## AGW Setup

### 1. Create the Secret

```bash
kubectl --context ${CONTEXT} -n agentgateway-system create secret generic snowflake-cortex-api-key \
  --from-literal=Authorization="Bearer ${SNOWFLAKE_PAT}" \
  --dry-run=client -o yaml | kubectl --context ${CONTEXT} apply -f -
```

### 2. Apply the Resources

```bash
kubectl --context ${CONTEXT} apply -f snowflake-cortex.yaml
```

This creates:
- `Secret/snowflake-cortex-api-key` — Bearer token for Snowflake auth
- `AgentgatewayBackend/snowflake-cortex-backend` — LLM backend pointing to Cortex
- `Gateway/snowflake-cortex-gw` — HTTP listener on port 8080
- `HTTPRoute/snowflake-cortex-route` — Routes all requests to the Cortex backend

**Note**: The YAML template has a placeholder PAT. Always create the secret separately with the real token (step 1) after applying the YAML.

### 3. Test

```bash
# Port-forward the gateway
kubectl --context ${CONTEXT} -n agentgateway-system port-forward svc/snowflake-cortex-gw 8080:8080 &

# Send a chat completion request (use max_completion_tokens, NOT max_tokens)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-large2",
    "messages": [{"role": "user", "content": "What is Snowflake Cortex?"}],
    "max_completion_tokens": 100
  }' | jq .
```

## Gotchas

| Issue | Symptom | Fix |
|-------|---------|-----|
| Wrong host format | HTTP 404 from Snowflake | Use `<org>-<account>` format, not `<account>-<org>` |
| No network policy | `390432: Network policy is required` | Create IP-based policy with `ALLOWED_IP_LIST` |
| Network rule format | `390432` persists after policy creation | Use `ALLOWED_IP_LIST`, not `ALLOWED_NETWORK_RULE_LIST` |
| Missing token type header | `390303: Invalid OAuth access token` | Add `X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN` via transformation |
| `max_tokens` parameter | `max_tokens is deprecated` error | Use `max_completion_tokens` instead |
| No HTTPRoute | `route not found` from AGW proxy | HTTPRoute is required to bind the backend to the gateway |
| Secret overwritten | `394400: Programmatic access token is invalid` | Re-apply secret with real PAT after `kubectl apply -f snowflake-cortex.yaml` |

## Available Cortex Models

Check [Snowflake Cortex model availability](https://docs.snowflake.com/en/user-guide/snowflake-cortex/llm-functions#availability) for your region. Common models:

| Model | Notes |
|-------|-------|
| `mistral-large2` | Mistral Large v2 |
| `llama3.1-70b` | Meta Llama 3.1 70B |
| `llama3.1-8b` | Meta Llama 3.1 8B |
| `claude-sonnet-4-5` | Anthropic Claude (if enabled) |
| `snowflake-arctic` | Snowflake's own model |

## Use Case

Snowflake Cortex runs within your Snowflake account, keeping data in your VPC — useful for organizations that cannot send data to external LLM providers.
