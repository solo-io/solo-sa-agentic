# User token passthrough

## Architecture

```
  Okta (OIDC IdP)
    │  1. user logs in → Okta issues JWT (T)
    │     aud: <AGENTCORE_AUDIENCE>, iss: https://<OKTA_DOMAIN>/oauth2/default
    ▼
  +--------+   Authorization: Bearer T
  | Client |──────────────────────────────────────────┐
  +--------+                                           │
                                                       ▼
  +--------------------------------------------------------------------+
  |  AgentGateway Enterprise (Red Hat OpenShift)                       |
  |                                                                    |
  |  HTTPRoute /agents/agentcore                                       |
  |    ├─ EnterpriseAgentgatewayPolicy: jwtAuthentication (Strict)     |
  |    │    validates T against Okta JWKS  ── fetch keys ──► Okta      |
  |    └─ AgentgatewayBackend spec.aws.agentCore                       |
  |         policies.auth.passthrough: {}                             |
  |           → re-adds the VALIDATED token as Authorization: Bearer T |
  +--------------------------------------------------------------------+
    │  2. POST .../runtimes/<arn>/invocations
    │     Authorization: Bearer T   (NO SigV4)
    ▼
  AWS
  +-----------------------------------------------+
  |  Bedrock AgentCore Runtime                    |
  |    customJWTAuthorizer                         |
  |      discoveryUrl: Okta OIDC discovery         |
  |      allowedAudience: [<AGENTCORE_AUDIENCE>]   │ ── validates T ──► Okta
  |    ┌──────────────────────────┐               |
  |    │ Strands Agent → Nova Lite │              |
  |    └──────────────────────────┘               |
  +-----------------------------------------------+
```

This example uses user-token passthrough for the inbound leg:

- A caller presents an Okta-issued JWT (`Authorization: Bearer <token>`).
- AgentGateway validates the JWT at the edge against Okta's JWKS, then passes the same token through to AgentCore unchanged.
- The AgentCore Runtime validates the JWT itself through its inbound `customJWTAuthorizer`, with Okta as the OIDC provider.

The gateway holds no IRSA, no SigV4, and no AWS credential for the invoke. The user's Okta identity travels all the way to AgentCore, which authorizes the call from the token rather than from an IAM principal.

> The SigV4/IRSA and STS AssumeRole variants (where the gateway holds an AWS identity and the user's identity terminates at the gateway) are documented separately in [`../README.md`](../README.md). This guide is the JWT-passthrough alternative for OpenShift.

Run these steps in order, since they share the environment variables exported in [Setup](00-setup.md).

## Step 1 — Create the AgentCore runtime with an Okta JWT authorizer

First, attach a `customJWTAuthorizer` pointing at Okta to the runtime we created in the [Setup](00-setup.md) doc.
  * `allowedAudience` validates the token's `aud` claim
  * `allowedClients` validates the `client_id` claim (see the note below — Okta access tokens carry the client id in `cid`, so prefer `allowedAudience`)

```bash
# Pull current config
CUR=$(aws bedrock-agentcore-control get-agent-runtime \
  --region "${AWS_REGION}" \
  --agent-runtime-id "${RID}")

aws bedrock-agentcore-control update-agent-runtime \
  --region "${AWS_REGION}" \
  --agent-runtime-id "${RID}" \
  --agent-runtime-artifact "$(echo "$CUR" | jq -c '.agentRuntimeArtifact')" \
  --role-arn "$(echo "$CUR" | jq -r '.roleArn')" \
  --network-configuration "$(echo "$CUR" | jq -c '.networkConfiguration')" \
  --authorizer-configuration '{
    "customJWTAuthorizer": {
      "discoveryUrl": "'"${OKTA_DISCOVERY}"'",
      "allowedAudience": ["'"${AGENTCORE_AUDIENCE}"'"]
    }
  }'
```

Once the authorizer is attached, the runtime accepts an `Authorization: Bearer <JWT>` and **no longer requires SigV4** — which is why the gateway needs no IAM identity for this leg.

---

## Step 3 — AgentGateway configuration on OpenShift

### 3a. Okta JWKS backend

Create a static backend to Okta's JWKS (for edge validation):

```bash
oc apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: okta-jwks
  namespace: agentgateway-system
spec:
  static:
    host: ${OKTA_DOMAIN}
    port: 443
  policies:
    tls: {}
EOF
```

### 3b. AgentCore backend — passthrough auth

Create an `AgentgatewayBackend` for the AgentCore Runtime with `policies.auth.passthrough: {}`:

```bash
oc apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentcore-backend
  namespace: agentgateway-system
spec:
  aws:
    agentCore:
      agentRuntimeArn: "${AGENT_RUNTIME_ARN}"
  policies:
    auth:
      passthrough: {}
EOF
```

### 3c. HTTPRoute

Next, create a route targeting the `AgentgatewayBackend` for AgentCore:

```bash
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agentcore-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /agents/agentcore
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: agentcore-backend
EOF
```

### 3d. Inbound JWT validation (Okta)

Create a `EnterpriseAgentgatewayPolicy` to validate the Okta token at the edge, so no unauthenticated caller can reach AgentCore. `mode: Strict` rejects requests with a missing or invalid token.

```bash
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: agentcore-inbound-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: agentcore-route
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

Confirm everything was accepted:

```bash
oc get agbe,httproute,eagpol -n agentgateway-system
oc get eagpol agentcore-inbound-jwt -n agentgateway-system \
  -o jsonpath='{.status.ancestors[0].conditions[*].type}={.status.ancestors[0].conditions[*].status}{"\n"}'
# Expect: Accepted=True  Attached=True
```

## Step 4 — Get an Okta user token

Use the Okta client created in the [Setup](00-setup.md) guide to issue a token:

```bash
# 1. Ask Okta for a device code
DEVICE=$(curl -s -X POST "${OKTA_ISSUER}/v1/device/authorize" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${OKTA_CLIENT_ID}" \
  -d "scope=openid agentcore.invoke")

echo "$DEVICE" | jq -r '"Go to \(.verification_uri_complete) and confirm"'
DEVICE_CODE=$(echo "$DEVICE" | jq -r .device_code)

# 2. After confirming in the browser, exchange the device code for a token
TOKENS=$(curl -s -X POST "${OKTA_ISSUER}/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  -d "device_code=${DEVICE_CODE}" \
  -d "client_id=${OKTA_CLIENT_ID}")

export USER_TOKEN=$(echo "$TOKENS" | jq -r .access_token)
```

---

## Step 5 — Test

Export the gateway address (only `:8080` HTTP is exposed on this cluster):

```bash
export AGW_LB=$(oc get gateway agentgateway-proxy -n agentgateway-system -o jsonpath='{.status.addresses[0].value}')
```

**Without a token — edge validation rejects it (verified live: `401`):**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "http://${AGW_LB}:8080/agents/agentcore" \
  -H "Content-Type: application/json" -d '{"prompt":"hi"}'
# HTTP 401
```

**With the Okta token — the gateway validates it, passes it through, and AgentCore validates it again:**

```bash
curl -s -X POST "http://${AGW_LB}:8080/agents/agentcore" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"prompt": "What is 2 plus 3?"}'
```

Expected response (SSE streaming):

```
data: "<thinking>..."
data: "The sum of 2 and 3 is 5."
```

### Request flow

```
Step 1: Client → AgentGateway (/agents/agentcore)
        Authorization: Bearer <Okta JWT>
        Policy: jwtAuthentication (Strict) validates the token against Okta JWKS

Step 2: AgentGateway → AgentCore
        AgentgatewayBackend spec.aws.agentCore builds the invocation path
        policies.auth.passthrough re-adds Authorization: Bearer <Okta JWT>  (NO SigV4)

Step 3: AgentCore Runtime
        customJWTAuthorizer validates the SAME token against Okta's discovery URL
        → Strands Agent → Nova Lite → SSE response
```

> ⚠️ **This flow carries a live user token over plain HTTP** (the `:8080` listener). That is acceptable only in a lab. For anything beyond one, terminate TLS on the gateway listener (HTTPS) and keep the AgentCore hop private. A captured `USER_TOKEN` is a replayable credential until it expires.
