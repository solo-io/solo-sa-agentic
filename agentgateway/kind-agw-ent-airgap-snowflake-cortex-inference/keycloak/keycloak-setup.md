# Keycloak JWT Authentication for AgentGateway Enterprise

## Architecture

```
Chatbot/Copilot                AGW Enterprise             Snowflake Cortex
     |                              |                          |
     |  1. client_credentials       |                          |
     |  ---------------------->  Keycloak                      |
     |  <-- JWT (5min TTL)          |                          |
     |                              |                          |
     |  2. Bearer $TOKEN            |                          |
     |  ---------------------->  JWT Validation                |
     |                         (JWKS from Keycloak)            |
     |                              |  3. Forward + PAT        |
     |                              |  -------------------->   |
     |  <---------------------------------------------------   |
```

Auth code flow is NOT appropriate for chatbot/copilot clients (no browser).
JWT with `client_credentials` grant is the recommended pattern per Christian Posta for programmatic API clients.

## Prerequisites

- Keycloak running in a container named `keycloak` (port 8088->8080)
- Realm `agentgateway` already created at http://keycloak.servebeer.com:8088/
- AGW Enterprise deployed (context: `${CONTEXT}` from env.sh)

## Step 1: Connect Keycloak to Kind Network

The Keycloak container runs on the Docker `bridge` network. Kind cluster uses the `kind` network. They must be connected.

```bash
docker network connect kind keycloak
```

Verify:
```bash
docker inspect -f '{{range $net, $config := .NetworkSettings.Networks}}{{$net}}: {{$config.IPAddress}}{{"\n"}}{{end}}' keycloak
# Expected: bridge: 172.17.0.4, kind: 172.18.0.2
```

## Step 2: Create K8s Service for Keycloak

```bash
kubectl --context ${CONTEXT} apply -f- <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: agentgateway-system
spec:
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: keycloak
  namespace: agentgateway-system
subsets:
  - addresses:
      - ip: 172.18.0.2
    ports:
      - port: 8080
        protocol: TCP
EOF
```

Verify from inside cluster:
```bash
kubectl --context ${CONTEXT} run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}" http://keycloak.agentgateway-system.svc:8080/realms/agentgateway/.well-known/openid-configuration
# Expected: 200
```

## Step 3: Create Keycloak Client for Chatbot

```bash
ADMIN_TOKEN=$(curl -s -X POST "http://keycloak.servebeer.com:8088/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token')

curl -s -X POST "http://keycloak.servebeer.com:8088/admin/realms/agentgateway/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "chatbot-client",
    "name": "Chatbot Client",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "chatbot-secret",
    "serviceAccountsEnabled": true,
    "standardFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "publicClient": false,
    "protocol": "openid-connect",
    "attributes": {
      "access.token.lifespan": "300"
    }
  }'
```

Key settings:
- `serviceAccountsEnabled: true` - enables `client_credentials` grant
- `standardFlowEnabled: false` - disables auth code flow (not needed for chatbots)
- `directAccessGrantsEnabled: false` - disables password grant
- Token TTL: 300s (5 minutes)

Verify token grant:
```bash
curl -s -X POST "http://keycloak.servebeer.com:8088/realms/agentgateway/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=chatbot-client&client_secret=chatbot-secret" | jq '{access_token: (.access_token[:50] + "..."), expires_in, token_type}'
```

## Step 4: Create JWT Auth Policy

```bash
kubectl --context ${CONTEXT} apply -f- <<'EOF'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt-auth-policy
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: snowflake-cortex-gw
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "http://keycloak.servebeer.com:8088/realms/agentgateway"
          jwks:
            remote:
              jwksPath: "/realms/agentgateway/protocol/openid-connect/certs"
              cacheDuration: "5m"
              backendRef:
                group: ""
                kind: Service
                name: keycloak
                namespace: agentgateway-system
                port: 8080
EOF
```

Key fields:
- `mode: Strict` - all requests MUST have a valid JWT
- `issuer` - must match the `iss` claim in the JWT exactly (external Keycloak URL)
- `backendRef` - points to in-cluster Keycloak Service for JWKS fetch
- `jwksPath` - relative path appended to the backendRef to reach the JWKS endpoint
- `cacheDuration` - caches JWKS keys for 5 minutes (reduces load on Keycloak)

Verify policy status:
```bash
kubectl --context ${CONTEXT} get eagpol jwt-auth-policy -n agentgateway-system -o jsonpath='{.status}' | jq .
# Expected: Accepted + Attached
```

## Step 5: Test

```bash
# Port-forward to reach the gateway
kubectl --context ${CONTEXT} port-forward -n agentgateway-system svc/snowflake-cortex-gw 18080:8080 &

# Test 1: No token → 401
curl -s -w "\nHTTP %{http_code}\n" http://localhost:18080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"snowflake-arctic","messages":[{"role":"user","content":"say hi"}]}'
# Expected: authentication failure: no bearer token found / HTTP 401

# Test 2: Valid token → passes through to backend
TOKEN=$(curl -s -X POST "http://keycloak.servebeer.com:8088/realms/agentgateway/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=chatbot-client&client_secret=chatbot-secret" | jq -r '.access_token')

curl -s -w "\nHTTP %{http_code}\n" http://localhost:18080/v1/chat/completions \
  -H "content-type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"model":"snowflake-arctic","messages":[{"role":"user","content":"say hello"}]}'
# Expected: JWT accepted (jwt.sub visible in proxy logs), request forwarded to Snowflake

# Kill port-forward
kill %1
```

## Proxy Log Verification

```bash
kubectl --context ${CONTEXT} logs -n agentgateway-system -l gateway=snowflake-cortex-gw --tail=10
```

Look for:
- `reason=JwtAuth` on 401s → AGW rejected (no/invalid token)
- `jwt.sub=<uuid>` on forwarded requests → AGW accepted the JWT and extracted the subject

## OIDC Discovery Endpoint

```
http://keycloak.servebeer.com:8088/realms/agentgateway/.well-known/openid-configuration
```

## Adding More Chatbot Clients

Register additional clients in Keycloak with the same pattern:
```bash
ADMIN_TOKEN=$(curl -s -X POST "http://keycloak.servebeer.com:8088/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token')

curl -s -X POST "http://keycloak.servebeer.com:8088/admin/realms/agentgateway/clients" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "copilot-2",
    "name": "Second Copilot",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "copilot-2-secret",
    "serviceAccountsEnabled": true,
    "standardFlowEnabled": false,
    "publicClient": false
  }'
```

No changes needed on the AGW side — any valid JWT from the `agentgateway` realm will be accepted.
