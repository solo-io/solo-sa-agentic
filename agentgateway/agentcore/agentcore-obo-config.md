# Entra OBO with AWS AgentCore as the Agent Runtime

This guide uses **AWS Bedrock AgentCore** as the agent runtime in the Entra On-Behalf-Of (OBO) token exchange flow, while keeping **agentgateway-enterprise** as the identity and governance layer. It has two parts:

- **Part 1 — Design**: the identity requirement, the three inbound-identity patterns, and why this guide uses the one it does.
- **Part 2 — Working demo**: end-to-end setup — Entra app registration, agentgateway-enterprise with token exchange, and an AgentCore-hosted **Strands agent** whose model calls flow through agentgateway to **Amazon Bedrock**, with an **Entra OBO** tool call to **Microsoft Graph**.

> This builds directly on the AgentCore routing setups in [`README.md`](README.md) (same directory). The AgentCore-side mechanics follow [Christian Posta's "Inbound Auth for AgentCore with Agentgateway"](https://blog.christianposta.com/inbound-auth-for-agentcore-with-agentgateway/) — this guide implements his Pattern 2.

---

# Part 1 — Design: How and Why

The goal: a user's Entra identity, preserved through an AgentCore-hosted agent, exchanged at agentgateway for a backend-scoped token — so every downstream call is attributable to and authorized as the *user*, not a shared service identity.

agentgateway's OBO machinery is runtime-agnostic. Its only contract:

> A request arriving at the OBO-policied route must carry `Authorization: Bearer <Entra-issued user access token>` whose audience is the app registration named in the policy's `clientId`.

The design question is therefore: **how does the user's token get into the AgentCore-hosted agent, and back out on the agent's calls through agentgateway?** The routing topology in [`README.md`](README.md) carries no user identity — the inbound test is an anonymous `curl`, the AgentCore hop is SigV4 with the *gateway's* AWS identity, and the MCP hop is public. This guide adds the identity layer on top of it.

## 1.1 The inbound-identity fork: three patterns

AgentCore Runtime accepts requests in exactly one of two authorizer modes (per runtime): **IAM (SigV4)** or **JWT (`customJWTAuthorizer`)**. Neither alone gives you gateway governance *and* a user token in the agent's hands, which leads to three composition patterns (from Christian's post).

**Callout**: SigV4 doesn't mint a new token or have anything to do with new token creation. Instead, its the credential that Bedrock accepts. SigV4 is a per-request signature computed from IAM credentials. With IRSA, the pod's role credentials appear automatically and agw signs automatically

| Pattern | AgentCore mode | How user identity travels | Agent gets a usable token for OBO? | Trade-off |
|---|---|---|---|---|
| 1. OBO token to AgentCore | JWT | agentgateway exchanges user JWT → OBO token (user `sub` + agent `act`); AgentCore validates it | Yes (the OBO token) | Strongest cryptographic chain; requires AgentCore to reach the token issuer's JWKS (publicly resolvable discovery URL) |
| **2. SigV4 + JWT in custom header** ⬅ this guide | IAM | agentgateway authenticates with SigV4; the user's original JWT rides an allowlisted custom header (`X-User-Authorization`) | **Yes (the original Entra token)** | Agent (or the next gateway hop) is responsible for treating the header value properly; header is opaque to AgentCore |
| 3. Claims as headers | IAM | agentgateway validates JWT at the edge, injects `X-Amzn-Bedrock-AgentCore-Runtime-User-Id` from `jwt.sub` | **No** (user-id string only) | Simplest; good for attribution/session isolation; **kills downstream OBO** — there is no token to exchange |

**Why Pattern 2 here:**

- It builds on the **already-validated** SigV4 setups in [`README.md`](README.md) (IRSA on EKS, AssumeRole on Kind) — no runtime auth-mode change.
- The agent receives the **original Entra token**, so the hairpin leg (`agent → agentgateway → OBO → backend`) is a standard Entra OBO exchange at the gateway. One token, one audience, one exchange.
- agentgateway stays in front of **both** legs (invoke and hairpin) — inbound JWT validation, and OBO + policy on the way out.
- Pattern 1 requires AgentCore to fetch JWKS from the token issuer. For Entra-issued tokens that's fine, but for agw-STS-issued OBO tokens the STS would have to be publicly reachable from AWS — more moving parts than a demo needs.

> **Security note (from the pattern's design):** `X-User-Authorization` is only trustworthy because *only agentgateway can invoke the runtime* — lock `bedrock-agentcore:InvokeAgentRuntime` to the gateway's IAM role. AgentCore treats custom headers as opaque values; it does not verify them. To close the loop, the gateway **mints this header itself** from the token it just validated (Step 7's transformation) and overwrites any client-supplied value — clients never control the carrier header.
>
> **Which token to propagate:** AgentCore Identity issues its own *workload access tokens*. Forwarding one of those instead of the **original Entra token** fails the exchange — the STS validates the subject token against Entra's JWKS. Always propagate the original user token.

## 1.2 Architecture

The agent makes **two** kinds of calls back through agentgateway, and they carry identity differently:

```
User (MSAL device-code login)                 T1 = Entra access token
  │                                            aud: <OBO_APP_CLIENT_ID>, scp: invoke
  │  Authorization: Bearer T1
  ▼
agentgateway :8080  /agents/obo               [jwtAuthentication validates T1, then a
  │                                            transformation mints the carrier header
  │  SigV4 (IRSA / AssumeRole)                 from the VALIDATED token]
  │  X-User-Authorization: Bearer T1          Authorization is now AWS-signed; the user
  ▼                                           token rides the gateway-minted custom header
AgentCore Runtime (IAM mode)
  │  Strands agent reads T1 from context.request_headers;
  │  model provider = agentgateway /llm (OpenAI-compatible, api_key = T1);
  │  whoami tool = agentgateway /graph (Microsoft Graph /me) with T1
  │
  ├────────── OBO leg (whoami tool call) ──────────────────────────────────┐
  │  Authorization: Bearer T1                                              │
  ▼                                                                        │
agentgateway :8080  /graph                    [tokenExchange.entra]        │
  │  Authorization: Bearer T2                  STS validates T1 vs Entra   │
  ▼                                            JWKS; Entra OBO: T1 → T2    │
Microsoft Graph (graph.microsoft.com)          (aud: Microsoft Graph)      │
  validates T2 and returns the USER's profile (/me)                        │
                                                                           │
  ┌────────── LLM leg (the agent's model calls) ─────────────────────────┘
  │  Authorization: Bearer T1
  ▼
agentgateway :8080  /llm                      [jwtAuthentication validates T1]
  │  SigV4 (gateway's IAM role)                user identity enforced at the
  ▼                                            gateway; no OBO — see §1.4
Amazon Bedrock (Nova Lite)
```

agentgateway is hit on every leg, same as the MCP flow in [`README.md`](README.md) — inbound proxy first, then Graph/LLM gateway on the hairpins.

## 1.3 The audience triangle

One Entra app registration (`agentcore-obo-api`) plays the middle-tier role, and the tokens must line up in three places:

1. **Login**: the device-code script requests scope `api://<OBO_APP_CLIENT_ID>/invoke` → T1's `aud` is `<OBO_APP_CLIENT_ID>`.
2. **OBO policy**: `spec.backend.tokenExchange.entra.clientId` = `<OBO_APP_CLIENT_ID>` — Entra requires the OBO assertion's audience to equal the exchanging app.
3. **Exchanged token**: the policy's `scope` is `https://graph.microsoft.com/.default`, so T2's audience is **Microsoft Graph** — which validates it and serves `/me` as the user. This is the canonical OBO scenario, and it requires the app's delegated `User.Read` Graph permission with admin consent (Step 1).

Get any leg wrong and you see `AADSTS50013` (assertion audience mismatch) or `AADSTS65001` (missing consent) in the exchange response, or a `401` from Graph. 

## 1.4 Where the credential swap happens: Bedrock for the LLM, OBO for protected APIs

LLM providers do not consume Entra tokens. The public Anthropic API wants `x-api-key`; Amazon Bedrock wants SigV4. So on any LLM leg, *something* terminates the user's Entra identity and switches to a provider credential — the only question is where, and with what credential material:

- **Public provider (e.g. `api.anthropic.com`)**: no third-party auth accepted, so a key-holding shim has to sit between the exchange and the provider. That's the right call in a non-AWS stack, but it means storing and rotating an API key.
- **Amazon Bedrock (this guide)**: the stack is already AWS-native — the gateway pod has an IAM identity (IRSA), and agentgateway has a **first-class Bedrock AI provider** (`AgentgatewayBackend` → `spec.ai.provider.bedrock`). The credential swap is Entra identity → SigV4, performed by the gateway itself, with **no key material anywhere**.

The consequence to be honest about: **OBO has no role on the Bedrock leg.** Bedrock can't validate an Entra token, so exchanging one for that hop would produce a token nothing consumes. User identity on the LLM leg is instead enforced *at the gateway*: `jwtAuthentication` on the `/llm` route rejects unauthenticated calls, and the validated claims are available for access logging, attribution, and per-user budget policy.

That leaves OBO to do its real job — **agent calling a protected API on behalf of the user** — and the demo points it at the real thing: **Microsoft Graph**. agentgateway exchanges the user's token for a Graph-audience token on the way out, and the agent reads the user's own profile (`/me`). Nothing is deployed to play the "protected API" role: Graph validates the exchanged token for real, the gateway and STS logs show the exchange happening, and the response shows whose identity arrived. The same policy attached to internal APIs or protected MCP targets extends the pattern to anywhere a per-user, audience-scoped token is consumed.

### The three credential domains (they never mix)

| Domain | Credential | Authenticates | Where it appears |
|---|---|---|---|
| User identity (Entra) | Access token **T1**, exchanged via OBO → **T2** | The **human** | Login → gateway JWT validation → `X-User-Authorization` into the agent → the agent's calls back through the gateway → OBO subject token → Graph |
| AWS identity (IAM) | **SigV4** signatures from the gateway pod's role (IRSA / AssumeRole) | The **gateway workload** — never the user | gateway → AgentCore invoke; gateway → Bedrock |
| Provider API key | — | An account/billing relationship | **Not used.** Only needed for public providers (e.g. `api.anthropic.com`). Bedrock *does* support API keys (`Authorization: Bearer`, attachable via the backend's `policies.auth.secretRef`) for environments without IAM ambient credentials — but on EKS with IRSA that would replace automatic, keyless rotation with a static secret |

Per leg:

```
user  → gateway /agents/obo   user authn = T1 (JWT policy)   │ gateway → AgentCore = SigV4 (gateway's role)
agent → gateway /llm          user authn = T1 (JWT policy)   │ gateway → Bedrock   = SigV4 (gateway's role)
agent → gateway /graph        user authn = T1 = OBO subject  │ gateway → Graph     = T2 (Entra, user-scoped)
```

Only the Graph leg carries the *user's* identity all the way to the destination — that's why it is the OBO leg. On the Bedrock leg the user's identity intentionally terminates at the gateway (logged, attributable, meterable), and AWS trust takes over from there. SigV4 is never "the user," and nothing SigV4 is ever exchanged — OBO operates purely on Entra tokens.

---

# Part 2 — Working Demo

## Prerequisites

- Kubernetes cluster with **agentgateway-enterprise** installable (EKS recommended for IRSA; Kind works with AssumeRole — see [`README.md`](README.md) Setup 2 for the ambient-credentials workaround)
- `kubectl`, Helm 3.x, AWS CLI, Python 3.11+, [`uv`](https://github.com/astral-sh/uv), the [AgentCore CLI](https://github.com/aws/agentcore-cli), `jq`
- An **agentgateway-enterprise license key**
- A **Microsoft Entra ID tenant** with admin access (the demo reads the signed-in user's Graph profile)
- An AWS account with Bedrock AgentCore available in your region (this guide uses `us-west-2`), and **Bedrock model access enabled** for `us.amazon.nova-lite-v1:0` — Nova Lite needs no use-case form; Anthropic models on Bedrock do (see the known issue in [`README.md`](README.md))
- The gateway's LoadBalancer must be reachable **from AgentCore** (AWS-hosted). On EKS this is the NLB. Note the known issue in [`README.md`](README.md): calls from AgentCore back to the gateway work over **HTTP via the NLB**; HTTPS with ACM certs has been observed to fail from inside AgentCore's environment.

## Step 1 — Entra app registration

Create **one** app registration that acts as the middle-tier API (login audience + OBO exchanger).

1. [Azure Portal → App registrations](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade) → **New registration**
   - Name: `agentcore-obo-api`, single tenant → **Register**
   - Note the **Application (client) ID** → `OBO_APP_CLIENT_ID`
   - Note the **Directory (tenant) ID** → `TENANT_ID`
2. **Certificates & secrets** → **New client secret** → copy the **Value** → `OBO_APP_CLIENT_SECRET`
3. **Expose an API**:
   - Set the Application ID URI to `api://<OBO_APP_CLIENT_ID>`
   - Add a delegated scope named `invoke` (admins and users can consent) and **grant admin consent**
4. **API permissions**: Microsoft Graph delegated `User.Read` is added by default on new registrations — click **Grant admin consent** so the OBO exchange to Graph succeeds without an interactive consent prompt
5. **Authentication** → set **Allow public client flows** to **Yes** (enables the device-code login in Step 8)
6. **Manifest** → set `"requestedAccessTokenVersion": 2` (v2 tokens: `iss` = `https://login.microsoftonline.com/<TENANT_ID>/v2.0`, `aud` = the client-ID GUID)

## Step 2 — Collect values

```bash
export TENANT_ID=<Entra tenant ID>
export OBO_APP_CLIENT_ID=<agentcore-obo-api client ID>
export OBO_APP_CLIENT_SECRET=<agentcore-obo-api client secret>
export AGW_LICENSE_KEY=<agentgateway-enterprise license key>
export AWS_ACCOUNT_ID=<AWS account ID>
export AWS_REGION=us-west-2
export AGW_VERSION=v2.2.0          # enterprise-agentgateway chart version
```

## Step 3 — Install agentgateway-enterprise with token exchange

Gateway API + enterprise CRDs (skip what you already have):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

helm upgrade --install agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --version ${AGW_VERSION} \
  --namespace agentgateway-system \
  --create-namespace
```

License secret:

```bash
kubectl create secret generic enterprise-agentgateway-license \
  -n agentgateway-system \
  --from-literal=enterprise-agentgateway-license-key="${AGW_LICENSE_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

`agw-values.yaml` — the token exchange (STS) server needs an issuer plus subject/API/actor validators. For Entra OBO the **subject** token is the user's Entra access token, so the subject validator points at Entra's JWKS:

```bash
cat > agw-values.yaml <<EOF
tokenExchange:
  enabled: true
  issuer: "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
  subjectValidator:
    validatorType: "remote"
    remoteConfig:
      url: "https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys"
  apiValidator:
    validatorType: "k8s"
  actorValidator:
    validatorType: "k8s"

controller:
  service:
    ports:
      tokenExchange: 7777

licensing:
  createSecret: false
  secretName: "enterprise-agentgateway-license"
EOF

helm upgrade --install agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version ${AGW_VERSION} \
  --namespace agentgateway-system \
  -f agw-values.yaml
```

## Step 4 — Gateway with STS wiring

The dataplane pods need the STS endpoint to perform exchanges. That comes from `EnterpriseAgentgatewayParameters`, referenced by the Gateway:

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentcore-obo-params
  namespace: agentgateway-system
spec:
  logging:
    level: debug
  env:
    - name: STS_URI
      value: "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/token"
    - name: STS_AUTH_TOKEN
      value: "/var/run/secrets/xds-tokens/xds-token"
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentcore-obo
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  infrastructure:
    parametersRef:
      group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayParameters
      name: agentcore-obo-params
  listeners:
    - name: http
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
```

Wait for the address, then export it:

```bash
kubectl get gateway agentcore-obo -n agentgateway-system -w
export AGW_LB=$(kubectl get gateway agentcore-obo -n agentgateway-system -o jsonpath='{.status.addresses[0].value}')
echo "Gateway: http://${AGW_LB}:8080"
```

## Step 5 — The two hairpin routes: `/graph` (OBO) and `/llm` (Bedrock)

Nothing gets deployed in this step — both targets already exist. Microsoft Graph is the OBO consumer (the canonical Entra OBO scenario), and Bedrock is the LLM. The exchange itself is verifiable in the gateway and STS logs (Step 9), and Graph's response shows whose identity arrived.

### 5a. `/graph` — the OBO leg

A static backend to `graph.microsoft.com`, with the token exchange policy attached to it. This is the exchange point: T1 in, T2 (Graph-audience) out (1.2).

```bash
kubectl create secret generic entra-obo-client-secret \
  -n agentgateway-system \
  --from-literal=client_secret="${OBO_APP_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: msgraph
  namespace: agentgateway-system
spec:
  static:
    host: graph.microsoft.com
    port: 443
  policies:
    tls: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: msgraph
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentcore-obo
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /graph
    filters:
    - type: URLRewrite
      urlRewrite:
        hostname: graph.microsoft.com
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: msgraph
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: entra-obo-token-exchange
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: AgentgatewayBackend
      name: msgraph
      group: agentgateway.dev
  backend:
    tokenExchange:
      mode: ExchangeOnly
      entra:
        tenantId: "${TENANT_ID}"
        clientId: "${OBO_APP_CLIENT_ID}"
        scope: "https://graph.microsoft.com/.default"
        clientSecretRef:
          name: entra-obo-client-secret
          key: client_secret
EOF
```

So `GET /graph/v1.0/me` through the gateway becomes `GET https://graph.microsoft.com/v1.0/me` carrying the exchanged Graph-audience token — Graph validates it and answers as the signed-in user.

### 5b. `/llm` — the Bedrock leg

Route `/llm` to a native Bedrock AI backend. No auth config on the backend: with `policies.auth` omitted, the proxy uses default AWS credential discovery — the pod's IAM role on EKS/IRSA (on Kind, add the AssumeRole block, same as the AgentCore backend in Step 7). No OBO here — Bedrock consumes SigV4, not Entra tokens (§1.4).

```bash
kubectl apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: bedrock-llm
  namespace: agentgateway-system
spec:
  ai:
    provider:
      bedrock:
        model: us.amazon.nova-lite-v1:0
        region: ${AWS_REGION}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bedrock-llm
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentcore-obo
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /llm
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplaceFullPath
          replaceFullPath: /v1/chat/completions
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: bedrock-llm
EOF
```

The gateway exposes the backend through its OpenAI-compatible API. The Strands agent's model provider (Step 6b) points its `base_url` at `/llm` with the **user's token as the API key**, so every model call the agent makes carries the user's identity through the gateway's JWT policy before agentgateway translates it to Bedrock.

## Step 6 — Create and deploy the AgentCore agent

### 6a. Scaffold

Follow the same CLI flow as [`README.md`](README.md):

```bash
agentcore create --name oboagent --defaults --skip-git --skip-install --protocol HTTP --output-dir .
cd oboagent/app/oboagent && uv sync && uv add 'strands-agents[openai]' httpx && cd -
cd oboagent/agentcore/cdk && npm install --legacy-peer-deps && cd -

cat > oboagent/agentcore/aws-targets.json <<JSON
[{"name": "default", "account": "${AWS_ACCOUNT_ID}", "region": "${AWS_REGION}"}]
JSON
```

The scaffold is already a Strands agent wired straight to Bedrock (`BedrockModel`). The `[openai]` extra adds the OpenAI-compatible model provider so the agent's model calls can go **through agentgateway** instead of straight to Bedrock — that's the whole point: the gateway sees, authenticates, and can meter every model call.

### 6b. Replace the entrypoint with the OBO agent

Replace the generated entrypoint (the file in `oboagent/app/oboagent/` containing `@app.entrypoint`) with the following — a **Strands agent** whose model provider is agentgateway's `/llm` route and whose `whoami` tool reads the user's Microsoft Graph profile through the OBO route. The user's Entra token (read from the allowlisted `X-User-Authorization` header) becomes the model provider's API key and the tool's bearer token — this per-request token propagation is what the whole OBO chain depends on:

```python
import httpx
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext
from strands import Agent, tool
from strands.models.openai import OpenAIModel

# EDIT ME: your gateway's LB address (Step 4). HTTP via the NLB — see the
# known issue about HTTPS from AgentCore in README.md.
AGW_BASE_URL = "http://<AGW_LB>:8080"

SYSTEM_PROMPT = (
    "You are a helpful assistant. When the user asks who they are, or asks you "
    "to prove their identity reached the backend, call the whoami tool (it reads "
    "their Microsoft Graph profile on their behalf) and include its result "
    "(displayName, userPrincipalName, id) in your answer."
)

app = BedrockAgentCoreApp()


def _user_token(context: RequestContext) -> str | None:
    """Extract the original Entra user token forwarded by agentgateway."""
    headers = context.request_headers or {}
    for name, value in headers.items():
        if name.lower() == "x-user-authorization":
            return value.removeprefix("Bearer ").strip()
    return None


@app.entrypoint
def invoke(payload, context: RequestContext):
    prompt = payload.get("prompt", "Who am I, according to Microsoft Graph?")

    token = _user_token(context)
    if not token:
        return {
            "error": "no X-User-Authorization header on the invocation",
            "hint": "check requestHeaderAllowlist and that the client sent the header",
        }

    # Captures the tool's raw result so Step 9 can verify it deterministically,
    # independent of how the model phrases its answer.
    obo_results: list[dict] = []

    @tool
    def whoami() -> dict:
        """Read the signed-in user's Microsoft Graph profile (/me) on their
        behalf. The call goes through agentgateway, which performs Entra
        On-Behalf-Of token exchange for a Graph-audience token on the way."""
        resp = httpx.get(
            f"{AGW_BASE_URL}/graph/v1.0/me",
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
        resp.raise_for_status()
        profile = resp.json()
        identity = {
            "displayName": profile.get("displayName"),
            "userPrincipalName": profile.get("userPrincipalName"),
            "id": profile.get("id"),
        }
        obo_results.append(identity)
        return identity

    # The model provider is agentgateway's OpenAI-compatible /llm route ->
    # Amazon Bedrock. The user's token is the API key, so the gateway's JWT
    # policy authenticates the USER on every model call the agent makes.
    model = OpenAIModel(
        client_args={
            "api_key": token,
            "base_url": f"{AGW_BASE_URL}/llm",
        },
        model_id="us.amazon.nova-lite-v1:0",
        params={"max_tokens": 1024},
    )

    agent = Agent(model=model, tools=[whoami], system_prompt=SYSTEM_PROMPT)
    result = agent(prompt)

    return {
        "response": str(result),
        "obo_identity": obo_results[-1] if obo_results else None,
    }


app.run()
```

> The agent loop makes **multiple** model calls per invocation (initial reasoning, then again after the tool result) — each one flows through `/llm` with the user's token, and each shows up in the gateway logs. That's the observability the hairpin buys you.

### 6c. Allowlist the user-token header

AgentCore only forwards custom headers named in the runtime's request-header allowlist (max 20 headers, **4KB each** — note that Entra tokens with large `groups` claims can exceed this; see Troubleshooting; `x-amz-*`/`x-amzn-*` prefixes are reserved). Add `X-User-Authorization` to the agent entry in `oboagent/agentcore/agentcore.json`:

```json
{
  "agents": [
    {
      "name": "oboagent",
      "requestHeaderAllowlist": [
        "X-User-Authorization"
      ]
    }
  ]
}
```

> Merge this into the existing agent entry rather than replacing the file wholesale — `agentcore create` scaffolds other fields you need to keep.
>
> Note: forwarding the standard `Authorization` header requires the runtime to be in `CUSTOM_JWT` authorizer mode. We're in IAM (SigV4) mode — that header slot belongs to AWS signing on this leg — which is exactly why the user token rides a *custom* header (§1.1, Pattern 2).

### 6d. Deploy

```bash
cd oboagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=${AWS_REGION} agentcore deploy --yes && cd -
```

Note the runtime ARN from the output:

```bash
export AGENT_RUNTIME_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/<YOUR_RUNTIME_ID>"
```

### 6e. IAM for the gateway's AWS calls

The gateway's identity makes **two** kinds of AWS calls: invoking the AgentCore runtime and invoking Bedrock models.

- **EKS (IRSA)** — follow [`README.md`](README.md) *Setup 1: IAM Setup* (IRSA role, service account annotated), and extend the policy with Bedrock model invocation:

  ```json
  {
    "Effect": "Allow",
    "Action": [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ],
    "Resource": "*"
  }
  ```

  Scope `Resource` down to your model/inference-profile ARNs for anything beyond a demo.

- **Kind (AssumeRole)** — follow [`README.md`](README.md) *Setup 2* (ambient creds + `agentcore-invoke-role`), adding the same Bedrock statement to the role's policy.

Keep the AgentCore invoke permission (`bedrock-agentcore:InvokeAgentRuntime*`) restricted to the gateway's role **only** — the trustworthiness of `X-User-Authorization` depends on agentgateway being the only possible invoker (§1.1).

## Step 7 — Inbound route: `/agents/obo` → AgentCore

```bash
kubectl apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentcore-obo-backend
  namespace: agentgateway-system
spec:
  aws:
    agentCore:
      agentRuntimeArn: "${AGENT_RUNTIME_ARN}"
EOF
```

> On EKS with IRSA, omitting `policies.auth.aws` makes the proxy sign with the pod's IAM role. On Kind, add the AssumeRole block from [`README.md`](README.md) / [`crs.yaml`](crs.yaml):
>
> ```yaml
>   policies:
>     auth:
>       aws:
>         assumeRole:
>           roleArn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/agentcore-invoke-role
> ```

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agentcore-obo-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentcore-obo
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /agents/obo
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: agentcore-obo-backend
EOF
```

### Validate the user's JWT and mint the carrier header (required)

This policy does two jobs on the inbound route, and the second is what the whole flow depends on:

1. **Validates T1** against Entra's JWKS — so nobody who can reach the LB can invoke the agent and spend Bedrock tokens.
2. **Mints `X-User-Authorization` at the gateway** from the *validated* token (`jwt.rawToken.unredacted()` in a request transformation). The client sends only a normal `Authorization` header; the gateway derives the carrier header itself and **overwrites anything the client supplied**, so the value the agent sees is always the token the gateway actually validated — no client-controlled second header, no mismatch risk.

```bash
kubectl apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: entra-jwks
  namespace: agentgateway-system
spec:
  static:
    host: login.microsoftonline.com
    port: 443
  policies:
    tls: {}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: agentcore-obo-inbound-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: agentcore-obo-route
      group: gateway.networking.k8s.io
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://login.microsoftonline.com/${TENANT_ID}/v2.0
          audiences:
            - "${OBO_APP_CLIENT_ID}"
            - "api://${OBO_APP_CLIENT_ID}"
          jwks:
            remote:
              jwksPath: ${TENANT_ID}/discovery/v2.0/keys
              backendRef:
                name: entra-jwks
                kind: AgentgatewayBackend
                group: agentgateway.dev
    transformation:
      request:
        set:
          - name: x-user-authorization
            value: '"Bearer " + jwt.rawToken.unredacted()'
EOF
```

Also recommended — the same JWT validation (without the transformation) on the `/llm` route, so unauthenticated callers can't spend Bedrock tokens on the hairpin either:

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: bedrock-llm-jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: bedrock-llm
      group: gateway.networking.k8s.io
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://login.microsoftonline.com/${TENANT_ID}/v2.0
          audiences:
            - "${OBO_APP_CLIENT_ID}"
            - "api://${OBO_APP_CLIENT_ID}"
          jwks:
            remote:
              jwksPath: ${TENANT_ID}/discovery/v2.0/keys
              backendRef:
                name: entra-jwks
                kind: AgentgatewayBackend
                group: agentgateway.dev
EOF
```

> **Not targeted: the `/graph` route** — JWT validation there would be redundant, since the STS already validates the subject token against the same Entra JWKS before exchanging (Step 3). It would also be *harmless*: JWT authentication strips the `Authorization` header after validating, but the token exchange falls back to the validated claims it leaves behind (`crates/agentgateway/src/proxy/token_exchange.rs` — the `Claims` extension fallback), so the exchange still gets its subject token either way. Skipping it just keeps one validation point per token instead of two.

## Step 8 — Get a user token (device-code login)

No UI needed — an MSAL device-code login plays the "user signs in" role:

```bash
cat > get-token.py <<'EOF'
import os
import sys

import msal

tenant_id = os.environ["TENANT_ID"]
client_id = os.environ["OBO_APP_CLIENT_ID"]

app = msal.PublicClientApplication(
    client_id,
    authority=f"https://login.microsoftonline.com/{tenant_id}",
)

flow = app.initiate_device_flow(scopes=[f"api://{client_id}/invoke"])
if "user_code" not in flow:
    sys.exit(f"device flow failed: {flow}")

print(flow["message"], file=sys.stderr)  # "go to https://microsoft.com/devicelogin and enter CODE"
result = app.acquire_token_by_device_flow(flow)

if "access_token" not in result:
    sys.exit(f"login failed: {result.get('error_description')}")

print(result["access_token"])
EOF

uv run --with msal python get-token.py > /tmp/user-token.txt
export USER_TOKEN=$(cat /tmp/user-token.txt)
```

Sanity-check the claims (`aud` must be `$OBO_APP_CLIENT_ID`, `scp` must contain `invoke`, `iss` must end in `/v2.0`):

```bash
# JWTs are base64url-encoded (and unpadded), so decode with python rather than base64 -d
python3 -c 'import base64,json,sys; p=sys.argv[1].split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))), indent=2))' "${USER_TOKEN}" \
  | jq '{aud, scp, iss, oid}'
```

## Step 9 — Invoke and verify the chain

Invoke the agent **through agentgateway** with a single, ordinary `Authorization` header. The gateway validates it, mints the `X-User-Authorization` carrier from the validated token (Step 7), and SigV4 takes over the `Authorization` slot on the AgentCore hop:

> ⚠️ **This demo carries live user tokens over plain HTTP** (the NLB path, forced by the HTTPS-from-AgentCore known issue). That is acceptable only in a lab. For anything beyond one: terminate TLS on the gateway listeners, or make the NLB/hairpin path private enough that a bearer token in cleartext fits your threat model. A captured `USER_TOKEN` is a replayable credential until it expires.

```bash
curl -s "http://${AGW_LB}:8080/agents/obo" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"prompt": "Who am I? Call your whoami tool and prove my identity reached Microsoft Graph."}'
```

Expected: the agent decides to call its `whoami` tool (OBO leg → Graph), gets the user's profile back, and answers through Bedrock (LLM leg) — with the tool's raw result attached for deterministic verification:

```json
{
  "response": "<the agent's answer, naming you — e.g. 'You are <display name> (<userPrincipalName>), confirmed by Microsoft Graph.'>",
  "obo_identity": {
    "displayName": "<your display name>",
    "userPrincipalName": "<you>@<tenant>",
    "id": "<your Entra object ID>"
  }
}
```

**Verify each hop:**

```bash
# 1. Gateway dataplane: inbound route, the OBO exchange on /graph, and the Bedrock calls on /llm
kubectl logs deploy/agentcore-obo -n agentgateway-system \
  | grep -E "agents/obo|graph|exchanging token|calling token exchange service|token exchange response|/llm"

# 2. STS: the exchange request itself (POST /token, 200)
kubectl logs deployment/enterprise-agentgateway -n agentgateway-system \
  | grep -Ei "token exchange|POST.*/token"

# 3. AgentCore: agent-side log (tool call + model calls)
agentcore logs   # or CloudWatch for the runtime

# 4. Policy status
kubectl get enterpriseagentgatewaypolicy -n agentgateway-system
kubectl describe eagpol entra-obo-token-exchange -n agentgateway-system
```

The proof of the whole exercise is the combination: hops 1–2 show the gateway performed a real exchange (STS `POST /token` 200), and `obo_identity` in the response is **Microsoft Graph answering as the user** — a token minted for a shared service identity could not read `/me` and get your profile back. Identity survived UI-less login → gateway → AgentCore → gateway → OBO exchange → Graph. Meanwhile the LLM leg ran on Bedrock with the gateway's IAM identity and zero stored keys.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AADSTS50013` / assertion audience error at exchange | T1's `aud` ≠ policy `clientId` | Request scope `api://<OBO_APP_CLIENT_ID>/invoke` at login; check Step 8 sanity check |
| `AADSTS65001` (consent) at device login or in the exchange response | A scope isn't consented | Grant admin consent on both the `invoke` scope and Graph `User.Read` (Step 1) |
| Graph returns `401 InvalidAuthenticationToken` | Exchange produced a token with the wrong audience | Policy `scope` must be `https://graph.microsoft.com/.default` (§1.3) |
| `/graph` fails with no exchange in the logs | Policy not attached to the `msgraph` backend | `kubectl describe eagpol entra-obo-token-exchange` and check the policy status/ancestors (a JWT policy on the route does *not* break the exchange — see the note in Step 7) |
| `obo_identity: null` in the response | The model chose not to call the `whoami` tool | Prompt explicitly ("call your whoami tool"); confirm the tool appears in the agent's config and the model supports tool use (Nova Lite does) |
| Agent returns `no X-User-Authorization header` | Header not allowlisted, or the minting policy isn't on the inbound route | Check `requestHeaderAllowlist` in `agentcore.json` and redeploy (`agentcore deploy`); confirm the Step 7 policy (jwt + transformation) targets `agentcore-obo-route` |
| Header allowlisted and policy attached, but the token still doesn't arrive | Token exceeds AgentCore's **4KB-per-header** limit — Entra access tokens bloat fast when the `groups` claim carries many groups | Keep the token lean: prefer app roles over group claims, filter groups emitted into the token (app registration → Token configuration), or rely on Entra's group-overage behavior instead of inline groups |
| `401` at gateway before anything happens | Inbound JWT policy rejecting T1 | Check issuer (`/v2.0` — requires `requestedAccessTokenVersion: 2`) and audiences in Step 7 |
| `/llm` returns `401` | JWT policy on the Bedrock route rejecting the agent's token | Same checks as above — the agent forwards T1, so if the inbound leg worked, this leg's token is identical |
| `/llm` returns an access-denied / model error | Gateway role lacks `bedrock:InvokeModel`, or model access not enabled | Extend IAM per Step 6e; enable Nova Lite model access in the Bedrock console for `us-west-2` |
| Agent's calls to the gateway time out | Gateway LB not reachable from AgentCore | Use the HTTP NLB address; see the HTTPS-from-AgentCore known issue in [`README.md`](README.md) |
| `AccessDeniedException` invoking AgentCore | Gateway identity lacks invoke permission | Re-check Step 6e (IRSA annotation / AssumeRole); on Kind, SSO creds expire ~hourly — recreate `aws-ambient-creds` |
| STS rejects the subject token | Wrong `subjectValidator`, or a non-Entra token was forwarded | The validator must be `remote` → Entra JWKS (Step 3), not `k8s`; and the agent must forward the original Entra user token, not an AgentCore workload token (§1.1) |

## Cleanup

```bash
kubectl -n agentgateway-system delete eagpol entra-obo-token-exchange agentcore-obo-inbound-jwt bedrock-llm-jwt
kubectl -n agentgateway-system delete agbe agentcore-obo-backend bedrock-llm msgraph entra-jwks
kubectl -n agentgateway-system delete httproute agentcore-obo-route msgraph bedrock-llm
kubectl -n agentgateway-system delete secret entra-obo-client-secret
kubectl -n agentgateway-system delete gateway agentcore-obo
kubectl -n agentgateway-system delete enterpriseagentgatewayparameters agentcore-obo-params

cd oboagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=${AWS_REGION} agentcore remove all --yes && cd -
# Plus the IAM policy/role from Step 6e, and the Entra app registration if no longer needed.
```

## Production notes

- **Split the app registrations** — the demo reuses one registration as both the public device-code client and the confidential OBO middle tier. In production, use two: a **public/native client** app for user login (no secret, requests the API's scope) and a **confidential middle-tier API** app that exposes the scope, holds the client secret, and is the `clientId` in the token exchange policy.
- **Scope the Graph permission** — the demo uses delegated `User.Read` and the `/.default` scope. Grant only the delegated permissions your tools actually need; the exchanged token carries exactly the consented set.
- **Real TLS on the inbound listener** — this demo is HTTP-only on `:8080`. Terminate TLS with a real cert on an HTTPS listener for anything user-facing, keeping in mind the AgentCore→gateway HTTPS known issue for the *hairpin* legs specifically.
- **Lock down the invoke path** — `bedrock-agentcore:InvokeAgentRuntime*` restricted to the gateway's role only; that's what makes `X-User-Authorization` trustworthy. Scope the `bedrock:InvokeModel` resource to the models you actually serve.
- **Extend OBO beyond Graph** — attach the same `tokenExchange.entra` policy to internal APIs or protected MCP targets on the hairpin, so each tool call carries a per-user, per-audience token.
- **Meter the LLM leg** — with JWT validation on `/llm`, the validated user claims are available at the gateway; agentgateway-enterprise budget/dimension policies can meter Bedrock spend per user, team, or model from there.
- **Chart drift** — pinned to `enterprise-agentgateway` `v2.2.0`. The `entra` token-exchange API (`spec.backend.tokenExchange.entra`) and the `bedrock` AI provider (`spec.ai.provider.bedrock`) are present on current `solo-main`; re-validate field names when bumping charts.

## References

- [`README.md`](README.md) — validated AgentCore routing setups this guide builds on (IRSA/AssumeRole, MCP hairpin, known issues)
- [Inbound Auth for AgentCore with Agentgateway](https://blog.christianposta.com/inbound-auth-for-agentcore-with-agentgateway/) — the three inbound patterns
- [Microsoft identity platform: OAuth 2.0 On-Behalf-Of flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow) — the Graph exchange this demo performs
- [Strands Agents: OpenAI model provider](https://strandsagents.com/docs/user-guide/concepts/model-providers/openai/) — the OpenAI-compatible provider pointed at the gateway
- AWS docs: [Configure inbound JWT authorizer](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/inbound-jwt-authorizer.html) · [Pass custom headers to AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-header-allowlist.html) · [Invoke an AgentCore Runtime agent](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-invoke-agent.html) · [Bedrock model access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)
- Upstream `aws.agentCore` backend support: [agentgateway PR #2037](https://github.com/agentgateway/agentgateway/pull/2037)
