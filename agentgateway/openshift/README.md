# AgentGateway + AWS Bedrock AgentCore on Red Hat OpenShift

This guide routes requests through **Solo Enterprise AgentGateway** running on **Red Hat OpenShift Container Platform (OCP)** to an **AWS Bedrock AgentCore** runtime, using **user-token passthrough** for the inbound leg:

- A caller presents an **Okta-issued JWT** (`Authorization: Bearer <token>`).
- AgentGateway **validates the JWT at the edge** against Okta's JWKS, then **passes the same token through unchanged** to AgentCore.
- The **AgentCore Runtime validates the JWT itself** via its inbound `customJWTAuthorizer` (Okta as the OIDC provider).

There is **no IRSA, no SigV4, and no AWS credential on the gateway** for the invoke — the user's Okta identity travels all the way to AgentCore, which authorizes the call from the token, not from an IAM principal.

> The SigV4/IRSA and STS AssumeRole variants (where the gateway holds an AWS identity and the user's identity terminates at the gateway) are documented separately in [`../agentcore/README.md`](../agentcore/README.md). This guide is the JWT-passthrough alternative for OpenShift.

This guide uses Amazon Nova Lite (`us.amazon.nova-lite-v1:0`). Anthropic models on Bedrock require a use case form submission in the AWS console; Nova Lite does not.


---

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

### The audience triangle

The same token must line up in three places, or the call is rejected:

1. **Token request** — the client asks Okta for a token whose `aud` is `<AGENTCORE_AUDIENCE>` (the custom authorization server's audience) and whose scope is granted by the app.
2. **Gateway** — `jwtAuthentication.providers[].issuer` = Okta issuer, `.audiences` = `<AGENTCORE_AUDIENCE>`.
3. **AgentCore** — `customJWTAuthorizer.discoveryUrl` = Okta OIDC discovery, `allowedAudience` = `[<AGENTCORE_AUDIENCE>]`.

Get any leg wrong and you see a `401` at the gateway (edge validation) or an authorization failure from AgentCore (`customJWTAuthorizer`).

---

## Prerequisites

- A **Red Hat OpenShift** cluster with AgentGateway Enterprise installed
  - Follow [these steps](https://github.com/solo-io/fe-enterprise-agentgateway-workshop/blob/main/labs/installation/openshift/001-set-up-enterprise-agentgateway-ocp.md)
- The `oc` CLI, authenticated to the cluster (`oc whoami`)
- An **Okta org** with permission to create an OIDC app and a custom authorization server
- An AgentCore runtime deployable via the AgentCore CLI (`agentcore deploy`)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2 (includes `bedrock-agentcore-control`)
- [node.js/npm](https://nodejs.org/en/download)
- [uv](https://github.com/astral-sh/uv#installation)

Collect these values up front:

```bash
export OKTA_DOMAIN="<your-org>.okta.com"          # no scheme
export OKTA_ISSUER="https://${OKTA_DOMAIN}/oauth2/default"
export OKTA_DISCOVERY="${OKTA_ISSUER}/.well-known/openid-configuration"
export AGENTCORE_AUDIENCE="api://default"         # your authorization server's audience
export OKTA_CLIENT_ID="<okta app client id>"      # the app requesting the token
export AWS_REGION="us-west-2"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

---

## Step 1 — Okta setup

1. **Authorization server** — Okta Admin → **Security → API**. Use the built-in `default` custom authorization server (or create your own). Note:
   - **Issuer**: `https://<OKTA_DOMAIN>/oauth2/default` → `OKTA_ISSUER`
   - **Audience**: set/read it here → `AGENTCORE_AUDIENCE` (e.g. `api://default`)
   - Under **Scopes**, add a scope the client will request (e.g. `agentcore.invoke`).
2. **Application** — Okta Admin → **Applications** → create an app that can obtain a **user** access token:
   - For an interactive user token, use an **OIDC → Native** app with the **Authorization Code** and/or **Device Authorization** grant enabled.
   - Note the **Client ID** → `OKTA_CLIENT_ID`.
3. **Access policy** — on the `default` authorization server, add an **Access Policy + Rule** that lets your app mint tokens for the scope above.

Verify the discovery URL resolves (AgentCore requires an endpoint ending in `/.well-known/openid-configuration`):

```bash
curl -s "${OKTA_DISCOVERY}" | jq '{issuer, jwks_uri, token_endpoint, device_authorization_endpoint}'
```

The `jwks_uri` is typically `https://<OKTA_DOMAIN>/oauth2/default/v1/keys` — the gateway fetches keys from there.

---

## Step 2 — Create the AgentCore runtime with an Okta JWT authorizer

Scaffold and deploy the agent (same flow as [`../agentcore/README.md`](../agentcore/README.md)):

```bash
# Install the AgentCore CLI: https://github.com/aws/agentcore-cli   (validated on v0.23.0)
agentcore create --name myagent \
  --framework Strands --model-provider Bedrock --memory none \
  --protocol HTTP --skip-git --skip-install --output-dir .

cd myagent/app/myagent && uv sync && cd -
cd myagent/agentcore/cdk && npm install --legacy-peer-deps && cd -

# The scaffold writes an empty aws-targets.json ([]) — populate it:
cat > myagent/agentcore/aws-targets.json <<JSON
[{"name": "default", "account": "${AWS_ACCOUNT_ID}", "region": "${AWS_REGION}"}]
JSON

# The Strands scaffold defaults to an Anthropic model (needs the Bedrock use case
# form). Switch to Nova Lite in myagent/app/myagent/model/load.py:
#   return BedrockModel(model_id="us.amazon.nova-lite-v1:0")

cd myagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=${AWS_REGION} agentcore deploy --yes && cd -

export AGENT_RUNTIME_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/<YOUR_RUNTIME_ID>"
```

**Put the runtime into JWT (OAuth) inbound mode.** Attach a `customJWTAuthorizer` pointing at Okta. `allowedAudience` validates the token's `aud` claim; `allowedClients` validates the `client_id` claim (see the note below — Okta access tokens carry the client id in `cid`, so prefer `allowedAudience`):

```bash
RID="<YOUR_RUNTIME_ID>"

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

Three resources: a static backend to Okta's JWKS (for edge validation), the AgentCore backend in **passthrough** mode, its route, and the inbound JWT policy.

### 3a. Okta JWKS backend

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

The `spec.aws.agentCore` backend still builds the AgentCore request (path, session id). What changes vs the IRSA setup is `policies.auth.passthrough: {}`: instead of SigV4-signing, the gateway **re-adds the validated client token** onto the request as `Authorization: Bearer <token>`.

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

> **What `passthrough` does** (from the CRD): *"Passes through an existing token that has been sent by the client and validated. Other policies, like JWT and API key authentication, will strip the original client credentials. Passthrough backend authentication causes the original token to be added back into the request."* So the JWT policy in 3d validates and strips the token at the edge, and passthrough restores it for the AgentCore hop. By default it is written to the `Authorization` header with the `Bearer ` prefix — exactly what AgentCore's JWT authorizer expects.

### 3c. HTTPRoute

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

Validate the Okta token at the edge, so no unauthenticated caller can reach AgentCore. `mode: Strict` rejects requests with a missing or invalid token.

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

---

## Step 4 — Get an Okta user token

Any Okta grant that yields an access token with the right `aud` works. For an interactive user token without a browser redirect handler, use the **device authorization** grant:

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

> **"Your device cannot be activated because of an internal error"** on the browser page (while `/v1/device/authorize` still returns a `user_code`): the `default` authorization server's **access-policy rule** doesn't allow the Device Authorization grant. That rule's grant list is separate from the app's — fix at Security → API → `default` → Access Policies → edit the rule → check **Device Authorization** → Update Rule. Also assign your user to the app and enable the app's **Refresh Token** grant.

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

---

## Limiting MCP tool access (optional extension)

If the agent also reaches out to MCP servers through AgentGateway (the full E2E flow in [`../agentcore/README.md`](../agentcore/README.md)), you can authorize MCP tools using the **same Okta claims** the inbound policy already validated. Define an MCP backend, then attach an authorization policy keyed off `jwt.*` claims.

```yaml
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
```

With JWT authentication configured (Step 3d), an `EnterpriseAgentgatewayPolicy` can gate tools per user. For example, scope each Okta subject to a specific MCP target/tool:

```yaml
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
```

You can list the tools a given token is allowed to see with the MCP inspector:

```bash
npx @modelcontextprotocol/inspector@0.21.2 \
  --cli "http://${AGW_LB}:8080/public/mcp" \
  --transport http \
  --method tools/list \
  --header "Authorization: Bearer ${USER_TOKEN}" | jq '.tools[].name'
```

See the AgentGateway docs for [limiting MCP tool access](https://docs.solo.io/agentgateway/latest/mcp/tool-access/#limit-tool-access) and [validating JWTs on MCP routes](https://docs.solo.io/agentgateway/latest/mcp/mcp-access/#validate-jwt-tokens).

---

## Auth Modes Reference

| `policies.auth` on the AgentCore backend | Credential on the AgentCore hop | AgentCore inbound mode |
|---|---|---|
| `passthrough: {}` (this guide) | The client's own token, re-added after edge validation | JWT (`customJWTAuthorizer`) |
| omitted | SigV4 from the pod's ambient creds (IRSA) | IAM (SigV4) |
| `aws: { assumeRole: {roleArn: ...} }` | STS AssumeRole → SigV4 with temp creds | IAM (SigV4) |
| `aws: { secretRef: {name: ...} }` | SigV4 with static creds from a Secret | IAM (SigV4) |

> The SigV4 rows are covered in [`../agentcore/README.md`](../agentcore/README.md). `passthrough` and the `aws.*` signing options are mutually exclusive on a given backend — a runtime is in *either* JWT *or* IAM inbound mode.

---

## Known Issues

1. **`allowedClients` vs Okta `cid`** — AgentCore's `allowedClients` validates the token's `client_id` claim, but Okta access tokens carry the client id in the `cid` claim, not `client_id`. Prefer **`allowedAudience`** (validates `aud`, which Okta sets reliably to the authorization server's audience). If you must pin the client, add a **required custom claim** rule on `cid` instead.

2. **Discovery URL format** — AgentCore requires a URL matching `^.+/\.well-known/openid-configuration$`. Okta's custom authorization server exposes `https://<OKTA_DOMAIN>/oauth2/default/.well-known/openid-configuration`; the org authorization server uses `https://<OKTA_DOMAIN>/.well-known/openid-configuration`. Use whichever matches the issuer that minted the token.

3. **HTTPS from AgentCore to a callback gateway** — if the agent calls back to the gateway (e.g. for MCP), the AgentCore runtime has been observed to fail TLS init against ACM certs from inside its environment. Works over HTTP via the LoadBalancer. See [`../agentcore/README.md`](../agentcore/README.md).

4. **Anthropic models require a use case form** — the Bedrock `ConverseStream` API (used by the Strands SDK) requires the Anthropic use case form in the AWS console. Nova Lite works without any forms.

---

## Cleanup

```bash
# OpenShift resources
oc -n agentgateway-system delete eagpol agentcore-inbound-jwt mcp-tool-access --ignore-not-found
oc -n agentgateway-system delete agbe agentcore-backend okta-jwks public-mcp-backend --ignore-not-found
oc -n agentgateway-system delete httproute agentcore-route --ignore-not-found

# AgentCore runtime
cd myagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=${AWS_REGION} agentcore remove all --yes && cd -

# Okta: remove the app and the custom scope/access-policy rule if no longer needed.
```
