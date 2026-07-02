# AgentGateway — OAuth2 client_credentials via ext-authz (v2026.6.2+)

Demonstrates how AgentGateway acquires a JWT from an OAuth2 IdP (Okta) using
the `client_credentials` grant type, then injects it into upstream requests.
No custom code — the entire flow is handled by AgentGateway's native ext-authz
with CEL expressions, shipped in PR `agentgateway/agentgateway#2284` (v2026.6.2).

## Use Case

Machine-to-machine (M2M) clients that cannot use browser-based OAuth flows
need to reach backend services through AgentGateway with JWT authentication.
AgentGateway acquires the token on behalf of the client automatically.

```
Client request
  -> AgentGateway (ext-authz calls IdP /token endpoint, acquires JWT)
    -> Backend service (receives request with Authorization: Bearer <jwt>)
```

## Okta Requirements

### 1. Create the OIDC Application

Create an OIDC application in your Okta tenant:

| Setting | Value |
|---------|-------|
| Application type | API Services (or Web with `client_credentials` enabled) |
| Grant type | `client_credentials` (must be explicitly enabled) |
| Client authentication | Client secret |

After creating the app, note:
- **Okta domain**: e.g. `dev-12345.okta.com`
- **Client ID**: from the app's General tab
- **Client secret**: from the app's General tab

### 2. Configure the Authorization Server

The authorization server controls **what goes into the JWT** — scopes, audience, and
custom claims. Okta makes this decision at token issuance time; AgentGateway does not
control JWT content.

Navigate to **Security > API > Authorization Servers** in your Okta admin console.
Use the `default` server or create a custom one.

#### Scopes

Add custom scopes that represent your use cases. Each scope appears in the JWT `scp`
claim when requested in the `client_credentials` grant.

| Scope | Description | Example use |
|-------|-------------|-------------|
| `api.access` | General API access | Default scope for all M2M clients |
| `llm.chat` | Chat completion access | Route to chat LLM backends |
| `llm.embeddings` | Embedding model access | Route to embedding backends |

To add a scope: **Authorization Server > Scopes > Add Scope**.

#### Access Policies

Access policies control which applications can request which scopes using which
grant types. You need a policy + rule that allows `client_credentials`.

1. **Authorization Server > Access Policies > Add Policy**
   - Name: e.g. `M2M API Access`
   - Assign to: the OIDC app you created (or `All clients`)

2. **Add Rule** to the policy:
   - Grant type: check **Client Credentials**
   - Scopes: select the scopes you want this app to be able to request
   - Example: allow `api.access`, `llm.chat`, `llm.embeddings`

Without this rule, Okta returns `invalid_scope` on the token request.

#### Custom Claims (optional)

If the backend needs additional metadata beyond standard JWT claims, add custom
claims to the authorization server:

1. **Authorization Server > Claims > Add Claim**
2. Configure:
   - Name: e.g. `use_case` or `department`
   - Include in: Access Token
   - Value type: Expression or Groups
   - Value: e.g. `app.profile.use_case` (reads from the app's profile)

Custom claims appear as top-level fields in the JWT payload alongside `iss`, `sub`,
`aud`, `scp`, etc.

### 3. What Ends Up in the JWT

When AgentGateway calls Okta's `/token` endpoint with `client_credentials`, Okta
evaluates the access policy and returns a JWT with these standard claims:

| Claim | Source | Example |
|-------|--------|---------|
| `iss` | Authorization server issuer URI | `https://dev-12345.okta.com/oauth2/default` |
| `sub` | Client ID of the OIDC app | `<your-client-id>` |
| `aud` | Authorization server audience | `api://default` |
| `scp` | Scopes requested in the grant | `["api.access", "llm.chat"]` |
| `cid` | Client ID (Okta-specific) | `<your-client-id>` |
| `exp` | Token expiry (configurable in Okta) | `1719878400` |
| _custom_ | Any custom claims you defined | `{"use_case": "chat"}` |

The backend LLM service reads these claims (especially `scp`) to decide which
model or use case to serve. AgentGateway passes the JWT as-is in the
`Authorization: Bearer <token>` header — it does not modify or validate the claims.

### 4. Verify Credentials

Test the client_credentials grant directly before configuring AgentGateway:

```bash
curl -s -X POST "https://<YOUR_OKTA_DOMAIN>/oauth2/default/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "<OKTA_CLIENT_ID>:<OKTA_CLIENT_SECRET>" \
  -d "grant_type=client_credentials&scope=api.access"
```

You should get a JSON response with `access_token` and `expires_in`. Decode the
token to verify the claims:

```bash
# Extract and decode the JWT payload
TOKEN=$(curl -s -X POST "https://<YOUR_OKTA_DOMAIN>/oauth2/default/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "<OKTA_CLIENT_ID>:<OKTA_CLIENT_SECRET>" \
  -d "grant_type=client_credentials&scope=api.access" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Confirm that `scp`, `aud`, and any custom claims match what you expect.

## 1. Create Kind Cluster

```bash
export CLUSTER_NAME=agw-client-creds
export KIND_IMAGE=kindest/node:v1.33.1
kind create cluster --name $CLUSTER_NAME --image $KIND_IMAGE
export CONTEXT=kind-$CLUSTER_NAME
```

> K8s 1.33+ is required for AGW v2026.6.2 CRDs (CEL validation rules).

## 2. Install Gateway API CRDs

```bash
kubectl --context $CONTEXT apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

## 3. Install AgentGateway Enterprise v2026.6.2

```bash
export AGW_NAMESPACE=agentgateway-system
export AGW_REGISTRY=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts

kubectl --context $CONTEXT create namespace $AGW_NAMESPACE

# CRDs — server-side apply avoids conflicts if kGateway CRDs are also installed
helm template -n $AGW_NAMESPACE --version v2026.6.2 \
  enterprise-agentgateway-crds $AGW_REGISTRY/enterprise-agentgateway-crds | \
  kubectl --context $CONTEXT apply --server-side --force-conflicts -f -

# Control plane
helm upgrade -i --kube-context $CONTEXT -n $AGW_NAMESPACE --version v2026.6.2 \
  enterprise-agentgateway $AGW_REGISTRY/enterprise-agentgateway \
  --set-string licensing.licenseKey=$AGENTGATEWAY_LICENSE_KEY \
  --set externalSecrets.stores=null \
  --skip-crds
```

> `--set externalSecrets.stores=null` is required — v2026.6.2 introduced
> `externalSecrets.stores` in the Helm values and omitting it causes a nil
> pointer error during template rendering.

## 4. Deploy httpbin (mock backend)

```bash
kubectl --context $CONTEXT create namespace backend
kubectl --context $CONTEXT apply -f httpbin.yaml
```

## 5. Deploy Gateway and HTTPRoute

```bash
kubectl --context $CONTEXT apply -f gateway.yaml
kubectl --context $CONTEXT apply -f httproute.yaml
```

This creates:
- A `Gateway` named `agw-demo` on port 8080 using the `enterprise-agentgateway` gateway class
- An `HTTPRoute` named `httpbin-route` routing all traffic to `httpbin:8000` in the `backend` namespace
- A `ReferenceGrant` allowing the cross-namespace backend reference

Wait for the gateway to be programmed:

```bash
kubectl --context $CONTEXT -n $AGW_NAMESPACE get gateway agw-demo
```

## 6. Deploy ext-authz Policy (client_credentials)

First, edit the YAML files with your Okta values:

- **`okta-backend.yaml`** — replace `<YOUR_OKTA_DOMAIN>` with your Okta domain
- **`okta-extauth-policy.yaml`** — replace `<OKTA_CLIENT_ID>` and `<OKTA_CLIENT_SECRET>`

If you use a custom authorization server (not `default`), also update the `path` field
in the policy (e.g. `"/oauth2/<auth-server-id>/v1/token"`).

If you use a scope other than `api.access`, update both the `scope` in the `body` CEL
expression and the cache `key`.

Then apply:

```bash
kubectl --context $CONTEXT apply -f okta-backend.yaml
kubectl --context $CONTEXT apply -f okta-extauth-policy.yaml
```

Verify both resources are accepted:

```bash
kubectl --context $CONTEXT -n $AGW_NAMESPACE get agentgatewaybackend okta-token
kubectl --context $CONTEXT -n $AGW_NAMESPACE get agentgatewaypolicy okta-client-creds -o jsonpath='{.status.ancestors[0].conditions}' | python3 -m json.tool
```

## 7. Test

```bash
# Port-forward the AGW gateway
kubectl --context $CONTEXT -n $AGW_NAMESPACE port-forward svc/agw-demo 28080:8080 &

# First request — AGW calls Okta /token, acquires JWT, injects it (~300-750ms)
curl -s http://localhost:28080/get | python3 -m json.tool

# Second request — cached token reuse (~2ms)
curl -s http://localhost:28080/get | python3 -m json.tool
```

In the httpbin response, look for the `Authorization` header — it should contain
`Bearer eyJ...` (the JWT acquired from Okta by AgentGateway).

## How It Works

```
1. Request arrives at AgentGateway
2. ext-authz intercepts (before routing to backend)
3. Check cache for key "client-credentials:api.access"
   ├── Cache HIT:  skip to step 6 (~2ms)
   └── Cache MISS: continue to step 4 (~300-750ms)
4. AGW builds HTTP request from CEL expressions:
   - Method:  POST (via :method pseudo-header)
   - URL:     https://<OKTA_DOMAIN>/oauth2/default/v1/token
   - Headers: Content-Type: application/x-www-form-urlencoded
              Authorization: Basic <base64(client_id:client_secret)>
   - Body:    grant_type=client_credentials&scope=api.access
5. IdP returns 200 with JSON: {"access_token": "eyJ...", "expires_in": 3600}
6. responseMetadata CEL extracts:
   - token:   json(response.body).access_token
   - expires: unvalidatedJwtPayload(token).exp
7. Cache stores result with TTL = exp - 5 seconds
8. transformation.request.set injects:
   - Authorization: Bearer <token>
9. Request continues to backend with JWT attached
```

### CEL Functions

| Function | Purpose |
|----------|---------|
| `form.encode({...})` | URL-encode a map as `application/x-www-form-urlencoded` body |
| `base64.encode(str)` | Base64-encode for HTTP Basic auth header |
| `json(response.body)` | Parse IdP JSON response |
| `unvalidatedJwtPayload(token)` | Extract JWT claims without signature validation (for expiry) |

