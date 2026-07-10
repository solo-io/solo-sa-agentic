## OBO token exchange on the agent's hairpin

The passthrough flow in doc 01 sends the user's Okta token straight to AgentCore and stops there. On-behalf-of (OBO) goes one step further: when the agent calls a protected downstream service, it calls back through AgentGateway, and the gateway exchanges the user's token (RFC 8693) for a fresh, downstream-scoped token on that hop. The user's identity reaches the downstream, but as a narrowed, short-lived token rather than the original. This is the same shape as the Entra/Graph flow in [`../agentcore-obo-config.md`](../agentcore-obo-config.md), adapted to Okta.

### Why the exchange lives on the hairpin, not the inbound leg

You might expect to exchange the token on the way in to AgentCore. That path does not work well. AgentCore's data-plane invocation requires a unique `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` (33+ characters) per conversation, and the `aws.agentCore` backend generates one for each request automatically. If you route to AgentCore through a plain `static` backend so the exchange can run, you lose that generation and have to set the header yourself. A hardcoded value collapses every caller into one session and leaks conversation history between them.

So the inbound leg keeps doc 01's `aws.agentCore` passthrough backend, which handles the session id. The exchange moves to where the agent actually calls a protected service: the hairpin.

```
User (Okta device login)                    T(user) = Okta access token
  │  Authorization: Bearer T(user)
  ▼
AgentGateway :8080  /agents/agentcore        jwtAuthentication validates T(user),
  │  passthrough → AgentCore                 then mints X-User-Authorization from it
  │  X-User-Authorization: Bearer T(user)    (aws.agentCore backend sets the session id)
  ▼
AgentCore Runtime (customJWTAuthorizer)
  │  Strands agent reads T(user) from the allowlisted X-User-Authorization header
  │
  └── tool call (hairpin) ─────────────────────────────────────┐
      │  Authorization: Bearer T(user)                          │
      ▼                                                         │
AgentGateway :8080  /downstream              tokenExchange.oauth │
  │  Authorization: Bearer T(obo)            Okta: T(user) → T(obo)
  ▼                                          (scp narrowed, cid = OBO app)
Protected downstream API
  validates T(obo) and serves the user
```

`T(obo)` is a subject-token exchange: same user (`sub` unchanged), re-minted with a narrower scope and short lifetime and issued to the OBO client. It does not carry an `act` (actor) claim for the agent. Actor-based delegation (`sub` plus `act`) is only available through agentgateway's built-in STS, whose issuer AgentCore in AWS cannot reach without exposing it publicly. This external-provider path keeps validation pointed straight at Okta, with no STS to run.

### Okta prerequisites for token exchange

This uses a second Okta app: a confidential client with a secret, separate from the Step 1 public/native app the user logs in with. Export its id and secret as `OKTA_OBO_CLIENT_ID` and `OKTA_OBO_CLIENT_SECRET`. On that app:

- Grant type: enable Token Exchange. Without it the exchange fails with `unauthorized_client: "...Configured grant types: [client_credentials]"`.
- Proof of possession: uncheck "Require DPoP header". Otherwise you get `invalid_dpop_proof`, because agentgateway authenticates with the client secret rather than DPoP.

On the `default` authorization server (Security → API → `default` → Access Policies), the rule must allow the Token Exchange grant and the requested scope (`agentcore.invoke`) for the client. Otherwise the exchange returns `access_denied: "Policy evaluation failed"`.

```bash
export OKTA_OBO_CLIENT_ID="<okta obo confidential client id>"
export OKTA_OBO_CLIENT_SECRET="<okta obo client secret>"
kubectl create secret generic okta-obo-client-secret -n agentgateway-system \
  --from-literal=client_secret="${OKTA_OBO_CLIENT_SECRET}" \
  --dry-run=client -o yaml | oc apply -f -
```

### Hand the user's token to the agent

The agent needs the user's token to make the hairpin call, but AgentCore does not pass the inbound `Authorization` header through to the agent. The gateway instead mints a custom `X-User-Authorization` header from the validated token, and AgentCore forwards it because it is on the runtime's allowlist.

Add the transformation to the Step 3d inbound JWT policy (this is doc 01's `agentcore-inbound-jwt`, re-applied with a `transformation` block). The gateway derives the header from the token it just validated and overwrites anything the client sent, so the agent always sees the real token:

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
    transformation:
      request:
        set:
          - name: x-user-authorization
            value: '"Bearer " + jwt.rawToken.unredacted()'
EOF
```

Allowlist the header on the runtime so AgentCore forwards it. The allowlist lives in the runtime's `requestHeaderConfiguration`; set it with `update-agent-runtime`. Any `update-agent-runtime` call replaces the runtime config, so pass the doc 01 `customJWTAuthorizer` in the **same** call — otherwise the authorizer resets to IAM:

```bash
CUR=$(aws bedrock-agentcore-control get-agent-runtime \
  --region "${AWS_REGION}" --agent-runtime-id "${RID}")

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
  }' \
  --request-header-configuration '{"requestHeaderAllowlist": ["X-User-Authorization"]}'
```

The allowlist holds up to 20 headers, 4KB each, and `x-amz-*` / `x-amzn-*` prefixes are reserved.

> The scaffold's `agentcore.json` has a `requestHeaderAllowlist` field under `runtimes[]`, but this CDK-managed deploy path does not push it to the runtime — set it with `update-agent-runtime` as above, not by editing `agentcore.json`. And run this **after** the `agentcore deploy` in "The agent's tool that hairpins" below, since every deploy clears it (see that section).

### The hairpin route and OBO exchange

The exchange calls Okta's token endpoint, then forwards the result to the downstream. Here the downstream is a self-hosted [go-httpbin](https://github.com/mccutchen/go-httpbin) running in the cluster, which echoes the headers it received so you can see the exchanged token arrive — keeping the token off the public internet. Point the same route at your real protected API in practice.

```bash
# Backend to Okta's token endpoint (the exchange target)
oc apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: okta-sts
  namespace: agentgateway-system
spec:
  static:
    host: ${OKTA_DOMAIN}
    port: 443
  policies:
    tls: {}
---
# The downstream protected API the agent's tool calls: self-hosted go-httpbin,
# which echoes the headers it received (so we can read back the exchanged token).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-httpbin
  namespace: agentgateway-system
  labels:
    app: go-httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: go-httpbin
  template:
    metadata:
      labels:
        app: go-httpbin
    spec:
      containers:
        - name: go-httpbin
          image: docker.io/mccutchen/go-httpbin:v2.15.0   # listens on :8080 by default; don't override args
          ports:
            - containerPort: 8080
          securityContext:                                 # satisfies OpenShift's restricted-v2 SCC
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          readinessProbe:
            httpGet:
              path: /status/200
              port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: go-httpbin
  namespace: agentgateway-system
spec:
  selector:
    app: go-httpbin
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
# Hairpin route the agent calls; rewrites the path to /headers so go-httpbin echoes them.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: downstream-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /downstream
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /headers
    backendRefs:
    - name: go-httpbin      # plain in-cluster Service (group "", kind Service)
      port: 8080
---
# The OBO exchange, attached to the hairpin route. Okta mints T(obo) from T(user).
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: downstream-obo-exchange
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: downstream-route
      group: gateway.networking.k8s.io
  backend:
    tokenExchange:
      oauth:
        backendRef:
          name: okta-sts
          kind: EnterpriseAgentgatewayBackend
          group: enterpriseagentgateway.solo.io
        path: /oauth2/default/v1/token
        subjectTokenType: urn:ietf:params:oauth:token-type:access_token
        audiences:
          - "${AGENTCORE_AUDIENCE}"
        scopes:
          - "agentcore.invoke"
        clientAuth:
          method: ClientSecretBasic
          clientId: "${OKTA_OBO_CLIENT_ID}"
          clientSecretRef:
            name: okta-obo-client-secret
            key: client_secret
EOF
```

Attach the exchange to the route, not to a backend. On the `aws.agentCore` backend the exchange is silently skipped; on a route it runs. If your real downstream is an `AgentgatewayBackend`, do not add `policies.auth.passthrough` to it, since passthrough re-adds the original token and would overwrite the exchanged one.

### The agent's tool that hairpins

Replace the entrypoint in `myagent/app/myagent/` with an agent whose `whoami` tool calls the hairpin route with the user's token. The gateway exchanges it before it reaches the downstream, so the token go-httpbin reports back is `T(obo)`, not the original. Set `AGW_BASE_URL` to your gateway's LB address (HTTP over the NLB; see the callback note in [`../agentcore-obo-config.md`](../agentcore-obo-config.md)).

```python
import base64
import json

import httpx
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext
from strands import Agent, tool
from strands.models.bedrock import BedrockModel

AGW_BASE_URL = "http://<AGW_LB>:8080"   # your gateway LB

SYSTEM_PROMPT = (
    "When the user asks to prove their identity reached the backend, call the "
    "whoami tool and report the token claims it returns."
)

app = BedrockAgentCoreApp()


def _user_token(context: RequestContext) -> str | None:
    for name, value in (context.request_headers or {}).items():
        if name.lower() == "x-user-authorization":
            return value.removeprefix("Bearer ").strip()
    return None


@app.entrypoint
def invoke(payload, context: RequestContext):
    prompt = payload.get("prompt", "Prove my identity reached the downstream.")
    token = _user_token(context)
    if not token:
        return {"error": "no X-User-Authorization header; check the allowlist and the inbound transformation"}

    seen: list[dict] = []

    @tool
    def whoami() -> dict:
        """Call the protected downstream through agentgateway, which performs the
        OBO exchange. Returns the claims of the token the downstream received."""
        resp = httpx.get(f"{AGW_BASE_URL}/downstream",
                         headers={"Authorization": f"Bearer {token}"}, timeout=30)
        resp.raise_for_status()
        auth = resp.json().get("headers", {}).get("Authorization", "")
        if isinstance(auth, list):          # go-httpbin echoes header values as arrays
            auth = auth[0] if auth else ""
        got = auth.removeprefix("Bearer ")
        claims = json.loads(base64.urlsafe_b64decode(
            got.split(".")[1] + "=" * (-len(got.split(".")[1]) % 4))) if got.count(".") == 2 else {}
        out = {k: claims.get(k) for k in ("jti", "sub", "aud", "cid", "scp")}
        seen.append(out)
        return out

    agent = Agent(model=BedrockModel(model_id="us.amazon.nova-lite-v1:0"),
                  tools=[whoami], system_prompt=SYSTEM_PROMPT)
    result = agent(prompt)
    return {"response": str(result), "downstream_token_claims": seen[-1] if seen else None}


app.run()
```

Add `httpx` to the agent's dependencies, then deploy:

```bash
cd myagent/app/myagent && uv add httpx && cd -
cd myagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=${AWS_REGION} agentcore deploy --yes && cd -
```

`agentcore deploy` (CDK) resets out-of-band runtime config — both the `customJWTAuthorizer` (back to IAM mode) and the `requestHeaderConfiguration` (allowlist cleared). Re-apply both with the combined `update-agent-runtime` call from "Hand the user's token to the agent" above after every deploy, or the agent stops seeing `X-User-Authorization` and returns the `no X-User-Authorization header` error.

### Test and verify the exchange

Invoke the agent through the inbound route with the user's token:

```bash
curl -s -X POST "http://${AGW_LB}:8080/agents/agentcore" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"prompt": "Prove my identity reached the downstream."}'
```

The `downstream_token_claims` in the response show the token the downstream received. Compare it with your own `USER_TOKEN`:

```bash
python3 -c 'import base64,json,sys;p=sys.argv[1].split(".")[1];print(json.dumps({k:json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))).get(k) for k in ("jti","sub","scp","cid")}))' "$USER_TOKEN"
```

The exchange worked if `sub` matches (still the user) but `jti` differs (a freshly minted token), `scp` is narrowed to `agentcore.invoke` (the original also has `openid`), and `cid` is the OBO client rather than the login app. If the claims are identical to your `USER_TOKEN`, the exchange did not run: check that the policy targets the route, that the OBO client secret is correct, and that the Okta prerequisites above are set.

Corroborate from the gateway logs and Okta's System Log:

```bash
oc logs deploy/agentgateway-proxy -n agentgateway-system | grep -iE "token_exchange|oauth|/v1/token|downstream"
# Okta Admin → Reports → System Log: a token exchange grant event on the default server
```
