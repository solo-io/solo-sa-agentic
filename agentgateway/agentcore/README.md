# AgentGateway + AWS Bedrock AgentCore

This guide covers routing LLM requests through Solo Enterprise AgentGateway to an AWS Bedrock AgentCore runtime. Two validated setups are included:

1. **Full E2E with MCP** — Client → AgentGateway (inbound) → AgentCore → AgentGateway (MCP gateway) → upstream MCP servers. Tested on EKS with IRSA auth.
2. **Minimal agent (no MCP)** — Client → AgentGateway → AgentCore. Tested on a Kind cluster with STS AssumeRole auth (PR [#2037](https://github.com/agentgateway/agentgateway/pull/2037)).

Both setups use Amazon Nova Lite (`us.amazon.nova-lite-v1:0`). Anthropic models on Bedrock require a use case form submission in the AWS console; Nova Lite does not.

---

## Architecture

AgentGateway is hit **twice** in the full E2E flow, serving two different roles:

```
                                     AWS
                                     +-----------------------------+
                                     |    Bedrock AgentCore        |
  +--------+                         |    Runtime                  |
  | Client |                         |  +----------------------+  |
  | (UI)   |                         |  | Strands Agent        |  |
  +---+----+                         |  |                      |  |
      |                              |  | Nova Lite LLM        |  |
      |                              |  | MCP Client ----------+--+--+
      |                              |  +----------------------+  |  |
      |                              +-----------------------------+  |
      |                                       ^                       |
      |                                       |                       |
      |  +------------------------------------+-------------------+   |
      |  |           AgentGateway (EKS)                           |   |
      |  |                                                        |   |
      |  |  ROLE 1: Inbound Proxy (:443)                          |   |
      |  |  +-----------+    +-----------------------+            |   |
      +---->| HTTPRoute |---->| AgentgatewayBackend  |            |   |
      |  |  | /agents/  |    | spec.aws.agentCore   |--- 2. ---->+   |
   1. |  |  | agentcore |    |                      |  SigV4         |
  HTTPS  |  +-----------+    | policies.auth.aws    |  signed        |
  :443|  |                    +-----------------------+               |
      |  |                                                            |
      |  |  ROLE 2: MCP Gateway (:8080)                               |
      |  |  +-----------+    +-----------------------+                |
      |  |  | HTTPRoute |---->| AgentgatewayBackend  |<--- 3. --------+
      |  |  | /public/  |    | spec.mcp.targets     |  streamable-http
      |  |  | mcp       |    |                      |  :8080
      |  |  +-----------+    | deepwiki, microsoft  |
      |  |                    +-----------------------+--- 4. ---> MCP servers
      |  +----------------------------------------------------+
```

### Two hits on AgentGateway in one request:

| Hit | Listener | Role | HTTPRoute | Backend | Auth |
|-----|----------|------|-----------|---------|------|
| 1st | `:443` (HTTPS) | Inbound proxy | `agentcore-route` | `agentcore-backend` (`spec.aws.agentCore`) | SigV4 via IRSA (pod IAM role) |
| 2nd | `:8080` (HTTP) | MCP gateway | `public-mcp` | `public-mcp-backend` (`spec.mcp.targets`) | None (public) |

---

## Setup 1: Full E2E on EKS (IRSA Auth)

### Prerequisites

- An EKS cluster with AgentGateway Enterprise installed
- An AgentCore runtime deployed via the AgentCore CLI (`agentcore deploy`)
- An IAM OIDC provider for your EKS cluster
  - For more details on how to create this, please see the [official AWS documentation on this topic](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)
- An IAM role configured for use with IRSA
  - For more details on how to create this, please see the [official AWS documentation on this topic](https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html)
- [AWS Cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [node.js/npm](https://nodejs.org/en/download)
- [uv](https://github.com/astral-sh/uv#installation)

### Create the AgentCore Runtime

```bash
# Install the AgentCore CLI: https://github.com/aws/agentcore-cli

# Create a new Strands-based agent
agentcore create --name myagent --defaults --skip-git --skip-install --protocol HTTP --output-dir .

# Install dependencies
cd myagent/app/myagent && uv sync && cd -
cd myagent/agentcore/cdk && npm install --legacy-peer-deps && cd -

# Configure the AWS target
cat > myagent/agentcore/aws-targets.json <<'JSON'
[{"name": "default", "account": "<YOUR_AWS_ACCOUNT_ID>", "region": "us-west-2"}]
JSON

# Change model to Nova Lite (no use case form needed)
# In myagent/app/myagent/model/load.py:
#   return BedrockModel(model_id="us.amazon.nova-lite-v1:0")

# Deploy
cd myagent && eval "$(aws configure export-credentials --format env)" && AWS_REGION=us-west-2 agentcore deploy --yes
```

### IAM Setup

Create an IAM policy that allows invoking the AgentCore runtime:

```json
cat > /tmp/iam-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeAgentRuntime",
        "bedrock-agentcore:InvokeAgentRuntimeForUser"
      ],
      "Resource": "arn:aws:bedrock-agentcore:us-west-2:<YOUR_AWS_ACCOUNT_ID>:runtime/*"
    }
  ]
}
EOF

aws iam create-policy --policy-name agentgateway-agentcore --policy-document file:///tmp/iam-policy.json
```

Attach the policy to an IRSA role and annotate the AgentGateway service account:

```bash
aws iam attach-role-policy --role-name <YOUR_IRSA_ROLE> --policy-arn=arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:policy/agentgateway-agentcore

kubectl annotate sa agentgateway -n agentgateway-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/<YOUR_IRSA_ROLE>

kubectl rollout restart deployment agentgateway -n agentgateway-system
```

### AgentgatewayBackend (AgentCore — IRSA)

When `policies.auth.aws` is omitted, the proxy uses the pod's IAM role via IRSA. No Secret needed.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentcore-backend
  namespace: agentgateway-system
spec:
  aws:
    agentCore:
      agentRuntimeArn: "arn:aws:bedrock-agentcore:us-west-2:<YOUR_AWS_ACCOUNT_ID>:runtime/<YOUR_RUNTIME_ID>"
```

### HTTPRoute (AgentCore)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agentcore-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway
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
```

### MCP Backend (for outbound MCP calls from AgentCore)

The agent code points its MCP client at `http://<NLB>:8080/public/mcp`. The gateway routes that to upstream MCP servers.

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

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: public-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway
      namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /public/mcp
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: public-mcp-backend
```

### Test (E2E)

```bash
curl -s -X POST "http://<NLB_ENDPOINT>:8080/agents/agentcore" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Use deepwiki to get the wiki structure of agentgateway/agentgateway"}'
```

### Request Flow

```
Step 1: Client -> AgentGateway (Inbound, :443)
        HTTPRoute: agentcore-route
        AgentgatewayBackend: agentcore-backend (spec.aws.agentCore)
        Auth: SigV4 via IRSA

Step 2: AgentGateway -> AgentCore (SigV4-signed)
        Protocol: HTTP (POST with {"prompt": "..."})
        Response: SSE streaming

Step 3: AgentCore Agent -> AgentGateway (MCP Gateway, :8080)
        MCP URL: http://<NLB>:8080/public/mcp
        Transport: streamable-http

Step 4: AgentGateway -> Upstream MCP Servers
        deepwiki (mcp.deepwiki.com) - GitHub repo documentation
        microsoft (learn.microsoft.com/api/mcp) - Microsoft docs
```

---

## Setup 2: Minimal Agent on Kind (AssumeRole Auth)

This setup tests `spec.aws.agentCore` routing with STS AssumeRole (PR [#2037](https://github.com/agentgateway/agentgateway/pull/2037)). No MCP — just a simple agent that answers questions.

### Prerequisites

- A Kind cluster with AgentGateway Enterprise installed
- An AgentCore runtime deployed via the AgentCore CLI
- AWS credentials available locally (SSO or static)

### IAM Setup: AssumeRole

Create a role that any identity in the account can assume:

```bash
aws iam create-role --role-name agentcore-invoke-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:root"},
      "Action": "sts:AssumeRole"
    }]
  }' --description "Role assumed by AGW proxy to invoke AgentCore runtimes"

aws iam put-role-policy --role-name agentcore-invoke-role --policy-name agentcore-invoke \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:InvokeAgentRuntime",
        "bedrock-agentcore:InvokeAgentRuntimeForUser"
      ],
      "Resource": "arn:aws:bedrock-agentcore:us-west-2:<YOUR_AWS_ACCOUNT_ID>:runtime/*"
    }]
  }'
```

### Inject Ambient AWS Creds into Proxy Pod

AssumeRole needs source credentials on the proxy. On EKS this is IRSA; on Kind, inject SSO creds as env vars:

```bash
eval "$(aws configure export-credentials --format env)" && \
kubectl -n agentgateway-system create secret generic aws-ambient-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
  --from-literal=AWS_REGION="us-west-2" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n agentgateway-system patch deploy <AGW_PROXY_DEPLOYMENT> --type json -p '[
  {"op": "add", "path": "/spec/template/spec/containers/0/envFrom", "value": [{"secretRef": {"name": "aws-ambient-creds"}}]}
]'
```

> **Note:** SSO tokens expire (~1 hour). Recreate `aws-ambient-creds` and restart the proxy when they expire.

### Auth: Two Options

AssumeRole can be configured either on the backend or as a separate policy. See [`crs.yaml`](crs.yaml) for both options.

**Option 1 — Auth on the AgentgatewayBackend** (every route pointing to this backend gets AssumeRole automatically):

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentcore-backend
  namespace: agentgateway-system
spec:
  aws:
    agentCore:
      agentRuntimeArn: "arn:aws:bedrock-agentcore:us-west-2:<YOUR_AWS_ACCOUNT_ID>:runtime/<YOUR_RUNTIME_ID>"
  policies:
    auth:
      aws:
        assumeRole:
          roleArn: arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/agentcore-invoke-role
```

**Option 2 — Auth on the EnterpriseAgentgatewayPolicy** (per-route scope):

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: agentcore-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - kind: HTTPRoute
      name: agentcore-route
      group: gateway.networking.k8s.io
  backend:
    auth:
      aws:
        assumeRole:
          roleArn: arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/agentcore-invoke-role
```

### HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agentcore-route
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: <YOUR_GATEWAY_NAME>
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
```

### Test

```bash
curl -s -X POST "http://<GATEWAY_IP>:8080/agents/agentcore" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2 plus 3?"}'
```

Expected response (SSE streaming):

```
data: "<thinking>..."
data: "The sum of 2 and 3 is 5."
```

### Auth Flow (AssumeRole)

```
Client → curl POST /agents/agentcore
  → AGW proxy
    → Reads ambient creds from env (AWS_ACCESS_KEY_ID, etc.)
    → STS AssumeRole(arn:aws:iam::<ACCOUNT>:role/agentcore-invoke-role)
      → Gets temporary credentials (AccessKeyId, SecretAccessKey, SessionToken)
    → SigV4 signs request with assumed role's temp creds
      → service=bedrock-agentcore, region=us-west-2
    → POST https://bedrock-agentcore.us-west-2.amazonaws.com/runtimes/.../invocations
      → AgentCore Runtime → Nova Lite LLM → SSE response
```

---

## Auth Modes Reference

| EAGPOL / Backend YAML | Source Creds | What Happens |
|----------------------|-------------|-------------|
| `aws: {}` | Pod ambient (IRSA/env) | SigV4-sign directly with ambient creds |
| `aws: { secretRef: {name: ...} }` | K8s Secret (accessKey, secretKey) | SigV4-sign with static creds from Secret |
| `aws: { assumeRole: {roleArn: ...} }` | Pod ambient (IRSA/env) | STS AssumeRole → SigV4-sign with temp creds |

> `secretRef` and `assumeRole` are **mutually exclusive** (CRD validation).

---

## Known Issues

1. **HTTPS from AgentCore to MCP Gateway** — The AgentCore runtime fails to initialize the MCP client when using HTTPS endpoints for the MCP gateway. Works fine with HTTP via the NLB directly. Likely an SSL/TLS issue with the ACM cert from within AgentCore's Lambda/container environment.

2. **Anthropic models require use case form** — The Bedrock `ConverseStream` API (used by Strands SDK) requires the Anthropic use case form to be submitted in the AWS console. Direct `InvokeModel` API works without it. Nova Lite works without any forms.

3. **REST OpenAPI backends via MCP** — Returns 404 when called via MCP protocol because the gateway forwards `/mcp` to the REST backend which does not understand MCP framing.

---

## Cleanup

### Kind Cluster

```bash
kubectl -n agentgateway-system delete eagpol agentcore-auth
kubectl -n agentgateway-system delete agbe agentcore-backend
kubectl -n agentgateway-system delete secret aws-ambient-creds
kubectl -n agentgateway-system delete httproute agentcore-route

# Remove envFrom patch from proxy
kubectl -n agentgateway-system patch deploy <AGW_PROXY_DEPLOYMENT> --type json -p '[
  {"op": "remove", "path": "/spec/template/spec/containers/0/envFrom"}
]'

# IAM resources
aws iam delete-role-policy --role-name agentcore-invoke-role --policy-name agentcore-invoke
aws iam delete-role --role-name agentcore-invoke-role
```

### EKS Cluster

```bash
kubectl -n agentgateway-system delete httproute agentcore-route public-mcp
kubectl -n agentgateway-system delete agbe agentcore-backend public-mcp-backend
```

### AgentCore Runtime

```bash
cd myagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=us-west-2 agentcore remove all --yes
```
