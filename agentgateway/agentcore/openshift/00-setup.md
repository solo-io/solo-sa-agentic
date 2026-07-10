# AgentGateway + AWS Bedrock AgentCore on Red Hat OpenShift

This guide routes requests through Solo Enterprise AgentGateway on Red Hat OpenShift Container Platform (OCP) to an AWS Bedrock AgentCore runtime.

This guide uses Amazon Nova Lite (`us.amazon.nova-lite-v1:0`). Anthropic models on Bedrock require a use case form submission in the AWS console; Nova Lite does not.

### The audience triangle

The same token must line up in three places, or the call is rejected:

1. Token request: the client asks Okta for a token whose `aud` is `<AGENTCORE_AUDIENCE>` (the custom authorization server's audience) and whose scope is granted by the app.
2. Gateway: `jwtAuthentication.providers[].issuer` is the Okta issuer, and `.audiences` is `<AGENTCORE_AUDIENCE>`.
3. AgentCore: `customJWTAuthorizer.discoveryUrl` is the Okta OIDC discovery URL, and `allowedAudience` is `[<AGENTCORE_AUDIENCE>]`.

---

## Prerequisites

- A Red Hat OpenShift cluster with AgentGateway Enterprise installed
  - Follow [these steps](https://github.com/solo-io/fe-enterprise-agentgateway-workshop/blob/main/labs/installation/openshift/001-set-up-enterprise-agentgateway-ocp.md)
- The `oc` CLI, authenticated to the cluster (`oc whoami`)
- An Okta org with permission to create an OIDC app and a custom authorization server
- An AgentCore runtime deployable via the AgentCore CLI (`agentcore deploy`)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) v2 (includes `bedrock-agentcore-control`)
- [node.js/npm](https://nodejs.org/en/download)
- [uv](https://github.com/astral-sh/uv#installation)

## Step 1: Okta setup

1. Authorization server: in Okta Admin, go to Security → API and use the built-in `default` custom authorization server (or create your own). Note:
   - The issuer `https://<OKTA_DOMAIN>/oauth2/default`, which you'll export as `OKTA_ISSUER`.
   - The audience, which you set or read here and export as `AGENTCORE_AUDIENCE` (for example `api://default`).
   - Under Scopes, add a scope the client will request (for example `agentcore.invoke`).
2. Application: in Okta Admin, go to Applications and create an app that can obtain a user access token. For an interactive user token, use an OIDC Native app with the Authorization Code and/or Device Authorization grant enabled. Note its Client ID and export it as `OKTA_CLIENT_ID`.
3. Access policy: on the `default` authorization server, add an Access Policy and Rule that lets your app mint tokens for the scope above.

Verify the discovery URL resolves (AgentCore requires an endpoint ending in `/.well-known/openid-configuration`):

```bash
curl -s "${OKTA_DISCOVERY}" | jq '{issuer, jwks_uri, token_endpoint, device_authorization_endpoint}'
```

The `jwks_uri` is typically `https://<OKTA_DOMAIN>/oauth2/default/v1/keys` — the gateway fetches keys from there.

---

## Step 2 — Create the AgentCore runtime with an Okta JWT authorizer

Scaffold and deploy the agent (same flow as [`../README.md`](../README.md)):

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

export RID="<YOUR_RUNTIME_ID>"
export AGENT_RUNTIME_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/$RID"
```
## Step 3 - Collect required ENV variables

These env variables will be referenced in the following guides:

```bash
export OKTA_DOMAIN="<your-org>.okta.com"
export OKTA_ISSUER="https://${OKTA_DOMAIN}/oauth2/default"
export OKTA_DISCOVERY="${OKTA_ISSUER}/.well-known/openid-configuration"
export AGENTCORE_AUDIENCE="api://default"         # your authorization server's audience
export OKTA_CLIENT_ID="<okta app client id>"      # the app requesting the token
export AWS_REGION="us-west-2"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

## Contents

1. [User token passthrough: Okta, AgentCore runtime, AgentGateway, token, and test](01-user-token-passthrough.md)
2. [OBO token exchange on the agent's hairpin](02-obo-token-exchange.md)
3. [MCP tool access control: identity, RBAC, and ABAC](03-mcp-access-control.md)
4. [Snowflake MCP server through AgentGateway](04-mcp-snowflake.md)
5. [Cleanup](05-cleanup.md)
