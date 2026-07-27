## MCP Auth

1. Get your MCP Gateway
```
kubectl get gateway -n agentgateway-system mcp-gateway
```

2. Open MCP Inspector in a new terminal
```
npx modelcontextprotocol/inspector#0.18.0
```

3. Specify, within the **URL** section, the following:
```
http://YOUR_ALB_IP:3000/mcp
```

You should now be able to see the connection without any security. This means that the MCP Server is wide open.

4. To implement auth security, add a gateway policy
```
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: mcp-gateway
  traffic:
    jwtAuthentication:
      providers:
        - issuer: solo.io
          jwks:
            inline: '{"keys": [{"kty": "RSA", "kid": "solo-public-key-001", "use": "sig", "alg": "RS256", "n": "vdV2XxH70WcgDKedYXNQ3Dy1LN8LKziw3pxBe0M-QG3_urCbN-oTPL2e0xrj5t2JOV-eBNaII17oZ6z9q84lLzn4mgU_UzP-Efv6iTZLlC_SD30AknifnoX8k38zbJtuwkvVcZvkam0LM5oIwSf4wJVpdPKHb3o_gGRpCBxWdQHPdBWMBPwOeqFfONFrM0bEnShFWf3d87EgckdVcrypelLyUZJ_ACdEGYUhS6FHmyojA1g6zKryAAWsH5Y-UCUuJd7VlOCMoBpAKK0BSdlF3WVSYHDlyMSB5H61eYCXSpfKcGhoHxViLgq6yjUR7TOHkJ-OtWna513TrkRw2Y0hsQ", "e": "AQAB"}]}'
EOF
```

5. Open the MCP Inspector and under **Authentication**, add in the following:
- Header Name: **Authorization**
- Bearer Token:
```
eyJhbGciOiJSUzI1NiIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImJvYiIsInRlYW0iOiJvcHMiLCJleHAiOjIwNzQyNzQ5NTQsImxsbXMiOnsibWlzdHJhbGFpIjpbIm1pc3RyYWwtbGFyZ2UtbGF0ZXN0Il19fQ.AZF6QKJJbnayVvP4bWVr7geYp6sdfSP-OZVyWAA4RuyjHMELE-K-z1lzddLt03i-kG7A3RrCuuF80NeYnI_Cm6pWtwJoFGbLfGoE0WXsBi50-0wLnpjAb2DVIez55njP9NVv3kHbVu1J8_ZO6ttuW6QOZU7AKWE1-vymcDVsNkpFyPBFXV7b-RIHFZpHqgp7udhD6BRBjshhrzA4752qovb-M-GRDrVO9tJhDXEmhStKkV1WLMJkH43xPSf1uNR1M10gMMzjFZgVB-kg6a1MRzElccpRum729c5rRGzd-_C4DsGm4oqBjg-bqXNNtUwNCIlmfRI5yeAsbeayVcnTIg
```

6. Clean up the policy
```
kubectl delete -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: mcp-gateway
  traffic:
    jwtAuthentication:
      providers:
        - issuer: solo.io
          jwks:
            inline: '{"keys": [{"kty": "RSA", "kid": "solo-public-key-001", "use": "sig", "alg": "RS256", "n": "vdV2XxH70WcgDKedYXNQ3Dy1LN8LKziw3pxBe0M-QG3_urCbN-oTPL2e0xrj5t2JOV-eBNaII17oZ6z9q84lLzn4mgU_UzP-Efv6iTZLlC_SD30AknifnoX8k38zbJtuwkvVcZvkam0LM5oIwSf4wJVpdPKHb3o_gGRpCBxWdQHPdBWMBPwOeqFfONFrM0bEnShFWf3d87EgckdVcrypelLyUZJ_ACdEGYUhS6FHmyojA1g6zKryAAWsH5Y-UCUuJd7VlOCMoBpAKK0BSdlF3WVSYHDlyMSB5H61eYCXSpfKcGhoHxViLgq6yjUR7TOHkJ-OtWna513TrkRw2Y0hsQ", "e": "AQAB"}]}'
EOF
```

## MCP Tool Isolation

### MCP Traffic Policy (no tools)

1. Add the traffic policy
```
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: tool-select
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: github-mcp-server
  backend:
    mcp:
      authorization:
        policy:
          matchExpressions:
            - 'mcp.tool.name == ""'
EOF
```

### MCP Traffic Policy (add tool)

1. Add the traffic policy
```
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: tool-select
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: github-mcp-server
  backend:
    mcp:
      authorization:
        policy:
          matchExpressions:
            - 'mcp.tool.name == "get_me"'
EOF
```

2. Cleanup

```
kubectl delete -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: tool-select
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: github-mcp-server
  backend:
    mcp:
      authorization:
        policy:
          matchExpressions:
            - 'mcp.tool.name == "get_me"'
EOF
```

## Elicitation

1. Clear previous ephemeral tokens by deleting the elicitation if it already exists:
```
1. Go to Elicitations tab
2. Click the three dots next to the elicitation
3. Delete it
```

2. Open the elicitation view:
https://34.74.210.205/age/elicitations


3. Open kagent:
https://34.74.210.205/ke/


4. Ask obo-readonly-agent:
`Use the GitHub MCP get_me tool to show my GitHub identity.`

5. The call should create a pending elicitation. Refresh /age/elicitations.

6. Click Authorize, complete GitHub consent, and return to the UI.

7. Retry the same prompt. It should now return the GitHub identity without another approval.

This requires the elicitation policy to be active and the static github-pat authentication removed. The controller restart makes the demo repeatable because your current token storage is ephemeral.

8. Restart the Gateway so you can reate a new pending elicitation if you want to show the process again
