# JWT Auth Pattern: JWT Validation for LLM Traffic

Demo of Enterprise authentication architecture: caller authenticates to Okta, obtains a JWT with custom scopes and claims, presents it to AgentGateway. AGW validates the token, enforces per-provider CEL RBAC, and routes to LLM providers.

## Architecture

```
                         ┌───────────────────────────────┐
                         │        AgentGateway           │
  ┌───────────────┐      │                               │     ┌──────────────┐
  │    Caller     │─────>│  1. Validate JWT (JWKS)       │────>│ OpenAI       │
  │               │      │  2. Check scope (CEL RBAC)    │     │ demo-llm     │
  │  Okta JWT     │      │  3. Route to provider         │     └──────────────┘
  │               │      │  4. Auth with platform creds  │     ┌──────────────┐
  │  Scopes:      │      │  5. Log identity + usage      │────>│ Anthropic    │
  │  llm:openai   │      │                               │     │demo-anthropic│
  │  llm:anthropic│      │                               │     └──────────────┘
  │  llm:gemini   │      │                               │     ┌──────────────┐
  │  location-data│      │                               │────>│ Gemini       │
  │  sales-data   │      │                               │     │ demo-gemini  │
  │               │      └───────────────────────────────┘     └──────────────┘
  │  Claims:      │
  │  team         │
  │  locations    │
  └───────────────┘
```

- AGW does NOT call Okta — it only validates the pre-minted JWT
- Per-provider scopes (`llm:openai`, `llm:anthropic`, `llm:gemini`) control which providers a caller can reach
- Custom claims (`team`, `locations`) flow through for audit/routing
- AGW authenticates to LLM providers with platform credentials (secrets), not user tokens

### What AGW sees (decoded JWT)

```json
{
  "ver": 1,
  "jti": "AT.z1cKAoZ3eNTXj70XFHrsAfEIqswYRKz8bDtmlDruozk",
  "iss": "https://<YOUR_OKTA_DOMAIN>/oauth2/default",
  "aud": "api://default",
  "iat": 1783552132,
  "exp": 1783555732,
  "cid": "<OKTA_CLIENT_ID>",
  "uid": "00u10872vxsVmP2HZ698",
  "scp": [
    "openid",
    "llm:openai",
    "llm:anthropic",
    "llm.access",
    "llm:gemini"
  ],
  "auth_time": 1783552025,
  "sub": "user1@example.com",
  "Groups": [
    "Everyone",
    "team-tracks"
  ],
  "locations": [
    "ATL-001",
    "ATL-002",
    "ATL-003"
  ],
  "team": "platform-engineering"
}
```

AGW validates `iss`, `aud`, and signature (via JWKS), then uses `scp`, `team`, `locations` for CEL RBAC and access logging.

## Environment

| Component | Value |
|-----------|-------|
| Cluster | `k3s-milano` |
| AGW Version | Enterprise 2026.6.3 |
| Gateway | `https` (443, TLS, `*.servebeer.com`) |
| Okta | `integrator-4829064.okta.com/oauth2/default` |

| Provider | Hostname | Backend | Scope |
|----------|----------|---------|-------|
| OpenAI | `demo-llm.servebeer.com` | `openai-llm` | `llm:openai` |
| Anthropic | `demo-anthropic.servebeer.com` | `anthropic-llm` | `llm:anthropic` |
| Gemini | `demo-gemini.servebeer.com` | `gemini-llm` | `llm:gemini` |

## Okta Setup

Custom scopes on the **default** authorization server (Security > API > Authorization Servers > default > Scopes):

| Scope | Description |
|-------|-------------|
| `llm.access` | Access LLM routes |
| `llm:openai` | OpenAI access |
| `llm:anthropic` | Anthropic access |
| `llm:gemini` | Gemini access |
| `location-data:read` | Read location data |
| `sales-data:write` | Write sales data |

Custom claims (Claims tab):

| Claim | Value | Type |
|-------|-------|------|
| `team` | `"platform-engineering"` | Expression, Access Token, Always |
| `locations` | `{"ATL-001","ATL-002","ATL-003"}` | Expression, Access Token, Always |

## Deploy

```bash
kubectl --context k3s-milano apply -f 01-okta-jwks-backend.yaml
kubectl --context k3s-milano apply -f 02-httproute.yaml
kubectl --context k3s-milano apply -f 03-jwt-auth-policy.yaml
kubectl --context k3s-milano apply -f 04-access-log-policy.yaml
kubectl --context k3s-milano apply -f 05-cel-rbac-policy.yaml
sed "s|\${ANTHROPIC_APIKEY}|${ANTHROPIC_APIKEY}|g" 06-anthropic-backend.yaml | kubectl --context k3s-milano apply -f -
kubectl --context k3s-milano apply -f 07-anthropic-route.yaml
sed "s|\${GEMINI_API_KEY}|${GEMINI_API_KEY}|g" 08-gemini-backend.yaml | kubectl --context k3s-milano apply -f -
kubectl --context k3s-milano apply -f 09-gemini-route.yaml
```

Verify all show `Accepted: True`:
```bash
kubectl --context k3s-milano get agentgatewaybackend,httproute,enterpriseagentgatewaypolicy -n agentgateway-system | grep -E "demo-|anthropic|gemini|openai"
```

## Test

### Get a token with all scopes

```bash
curl -s -X POST https://integrator-4829064.okta.com/oauth2/default/v1/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&client_id=0oazbypeztjL5nB6F697&client_secret=-EzCxn_ApRj8SQF8zPiZq8RSnnVF4y_cHTxpYJOvwEP2yE19JURtFDmUrrMXflV-&scope=llm.access llm:openai llm:anthropic llm:gemini location-data:read sales-data:write' \
  | jq -r '.access_token' | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

### Without token (expect 401)

```bash
curl -ik --resolve demo-llm.servebeer.com:443:192.168.0.212 \
  https://demo-llm.servebeer.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}'
```

### OpenAI — with token (expect 200)

```bash
curl -sk --resolve demo-llm.servebeer.com:443:192.168.0.212 \
  https://demo-llm.servebeer.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(curl -s -X POST https://integrator-4829064.okta.com/oauth2/default/v1/token -H 'Content-Type: application/x-www-form-urlencoded' -d 'grant_type=client_credentials&client_id=0oazbypeztjL5nB6F697&client_secret=-EzCxn_ApRj8SQF8zPiZq8RSnnVF4y_cHTxpYJOvwEP2yE19JURtFDmUrrMXflV-&scope=llm.access llm:openai location-data:read sales-data:write' | jq -r '.access_token')" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}'
```

### Anthropic — with token (expect 200)

```bash
curl -sk --resolve demo-anthropic.servebeer.com:443:192.168.0.212 \
  https://demo-anthropic.servebeer.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(curl -s -X POST https://integrator-4829064.okta.com/oauth2/default/v1/token -H 'Content-Type: application/x-www-form-urlencoded' -d 'grant_type=client_credentials&client_id=0oazbypeztjL5nB6F697&client_secret=-EzCxn_ApRj8SQF8zPiZq8RSnnVF4y_cHTxpYJOvwEP2yE19JURtFDmUrrMXflV-&scope=llm.access llm:anthropic location-data:read sales-data:write' | jq -r '.access_token')" \
  -d '{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}'
```

### Gemini — with token (expect 200)

```bash
curl -sk --resolve demo-gemini.servebeer.com:443:192.168.0.212 \
  https://demo-gemini.servebeer.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(curl -s -X POST https://integrator-4829064.okta.com/oauth2/default/v1/token -H 'Content-Type: application/x-www-form-urlencoded' -d 'grant_type=client_credentials&client_id=0oazbypeztjL5nB6F697&client_secret=-EzCxn_ApRj8SQF8zPiZq8RSnnVF4y_cHTxpYJOvwEP2yE19JURtFDmUrrMXflV-&scope=llm.access llm:gemini location-data:read sales-data:write' | jq -r '.access_token')" \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}'
```

### Wrong scope (expect 403)

Request OpenAI route with only `llm:anthropic` scope — should be denied by CEL RBAC:

```bash
curl -sk --resolve demo-llm.servebeer.com:443:192.168.0.212 \
  https://demo-llm.servebeer.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(curl -s -X POST https://integrator-4829064.okta.com/oauth2/default/v1/token -H 'Content-Type: application/x-www-form-urlencoded' -d 'grant_type=client_credentials&client_id=0oazbypeztjL5nB6F697&client_secret=-EzCxn_ApRj8SQF8zPiZq8RSnnVF4y_cHTxpYJOvwEP2yE19JURtFDmUrrMXflV-&scope=llm.access llm:anthropic location-data:read sales-data:write' | jq -r '.access_token')" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}],"max_tokens":5}'
```

### Check access logs

```bash
kubectl --context k3s-milano logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=https --tail=5
```

Expected log fields:
```
jwt.sub="0oazbypeztjL5nB6F697"
jwt.scp=["llm.access", "llm:openai", "location-data:read", "sales-data:write"]
jwt.team="platform-engineering"
jwt.locations=["ATL-001", "ATL-002", "ATL-003"]
model.requested="gpt-4o-mini"
tokens.input="8" tokens.output="5" tokens.total="13"
```

## How This Maps to Production

| This Demo | Production |
|-----------|----------------|
| `client_credentials` grant | OBO token exchange (user JWT → system JWT with scopes) |
| `scp: llm:openai, llm:anthropic, llm:gemini` | Per-provider scopes from Okta policy engine |
| `scp: location-data:read, sales-data:write` | Scopes tied to data domains behind MCP tools |
| `team: platform-engineering` | Team identity for chargeback/routing |
| `locations: [ATL-001, ...]` | Location-level permissions for internal app |
| 3 providers (OpenAI, Anthropic, Gemini) | Vertex AI (Gemini) + Anthropic (Claude) |
| `secretRef` for provider auth | GCP service account / API keys |
| JWT claims in access logs | Audit trail for compliance |
| CEL RBAC per route | Okta scopes = authorization decisions |
