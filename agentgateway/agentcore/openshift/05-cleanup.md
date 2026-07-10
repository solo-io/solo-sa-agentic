## Cleanup

```bash
# OpenShift resources
oc -n agentgateway-system delete eagpol \
  agentcore-inbound-jwt downstream-obo-exchange \
  public-mcp-jwt mcp-tool-access mcp-agent-rbac mcp-abac-change-ticket mcp-abac-deny-contractors \
  snowflake-mcp-jwt snowflake-mcp-rbac --ignore-not-found
oc -n agentgateway-system delete agbe agentcore-backend okta-jwks public-mcp-backend --ignore-not-found
oc -n agentgateway-system delete enterpriseagentgatewaybackend okta-sts snowflake-mcp-backend --ignore-not-found
oc -n agentgateway-system delete httproute agentcore-route downstream-route public-mcp snowflake-mcp-route --ignore-not-found
oc -n agentgateway-system delete deploy,svc go-httpbin --ignore-not-found
oc -n agentgateway-system delete secret okta-obo-client-secret snowflake-pat --ignore-not-found

# AgentCore runtime
cd myagent && eval "$(aws configure export-credentials --format env)" && \
  AWS_REGION=${AWS_REGION} agentcore remove all --yes && cd -

# Okta: remove the app and the custom scope/access-policy rule if no longer needed.
```
