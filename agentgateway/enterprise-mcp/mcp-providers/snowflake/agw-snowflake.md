# Connecting To Snowflakes MCP Server With AGW

## Secret Creation

```
export SNOWFLAKE_PAT=
```

```
kubectl create secret generic snowflake-pat \
  -n agentgateway-system \
  --from-literal=Authorization=$SNOWFLAKE_PAT \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Gateway Setup

1. Create a gateway for the MCP server you deployed
```
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mcp-snowflake
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: mcp
      port: 3000
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
EOF
```

2. Apply the backend so the gateway knows what to route to. In this case, it's an MCP server
```
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: snowflake-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
      - name: demo-mcp-server
        static:
          host: sx62370.ca-central-1.aws.snowflakecomputing.com
          port: 443
          path: /api/v2/databases/EDW_UNI_RBT_DEV/schemas/ROBOTICS_SALESFORCE/mcp-servers/ROBOTICS_SF_MCP_SERVER
          protocol: StreamableHTTP
          policies:
            tls:
              sni: sx62370.ca-central-1.aws.snowflakecomputing.com
            auth:
              secretRef:
                name: snowflake-pat
EOF
```

3. Apply the route so the MCP Server can be reached
```
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-snowflake-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: mcp-snowflake
  rules:
    - backendRefs:
      - name: snowflake-mcp-backend
        namespace: agentgateway-system
        group: enterpriseagentgateway.solo.io
        kind: EnterpriseAgentgatewayBackend
EOF
```

5. Capture the IP of the gateway
```
export GATEWAY_IP=$(kubectl get svc mcp-snowflake -n agentgateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $GATEWAY_IP
```

## Test The MCP Server

1. Open MCP Inspector
```
npx modelcontextprotocol/inspector#0.18.0
```

7. Specify, within the **URL** section, the following:
```
http://YOUR_ALB_IP:3000/mcp
```

You should now be able to see the connection without any security. This means that the MCP Server is wide open.

## Implement Auth

1. To implement auth security, add a gateway policy
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
      name: mcp-snowflake
  traffic:
    jwtAuthentication:
      providers:
        - issuer: solo.io
          jwks:
            inline: '{"keys": [{"kty": "RSA", "kid": "solo-public-key-001", "use": "sig", "alg": "RS256", "n": "vdV2XxH70WcgDKedYXNQ3Dy1LN8LKziw3pxBe0M-QG3_urCbN-oTPL2e0xrj5t2JOV-eBNaII17oZ6z9q84lLzn4mgU_UzP-Efv6iTZLlC_SD30AknifnoX8k38zbJtuwkvVcZvkam0LM5oIwSf4wJVpdPKHb3o_gGRpCBxWdQHPdBWMBPwOeqFfONFrM0bEnShFWf3d87EgckdVcrypelLyUZJ_ACdEGYUhS6FHmyojA1g6zKryAAWsH5Y-UCUuJd7VlOCMoBpAKK0BSdlF3WVSYHDlyMSB5H61eYCXSpfKcGhoHxViLgq6yjUR7TOHkJ-OtWna513TrkRw2Y0hsQ", "e": "AQAB"}]}'
EOF
```

2. Open the MCP Inspector and under **Authentication**, add in the following:
- Header Name: **Authorization**
- Bearer Token:
```
eyJhbGciOiJSUzI1NiIsImtpZCI6InNvbG8tcHVibGljLWtleS0wMDEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJzb2xvLmlvIiwib3JnIjoic29sby5pbyIsInN1YiI6ImJvYiIsInRlYW0iOiJvcHMiLCJleHAiOjIwNzQyNzQ5NTQsImxsbXMiOnsibWlzdHJhbGFpIjpbIm1pc3RyYWwtbGFyZ2UtbGF0ZXN0Il19fQ.AZF6QKJJbnayVvP4bWVr7geYp6sdfSP-OZVyWAA4RuyjHMELE-K-z1lzddLt03i-kG7A3RrCuuF80NeYnI_Cm6pWtwJoFGbLfGoE0WXsBi50-0wLnpjAb2DVIez55njP9NVv3kHbVu1J8_ZO6ttuW6QOZU7AKWE1-vymcDVsNkpFyPBFXV7b-RIHFZpHqgp7udhD6BRBjshhrzA4752qovb-M-GRDrVO9tJhDXEmhStKkV1WLMJkH43xPSf1uNR1M10gMMzjFZgVB-kg6a1MRzElccpRum729c5rRGzd-_C4DsGm4oqBjg-bqXNNtUwNCIlmfRI5yeAsbeayVcnTIg
```

3. Cleanup

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
      name: mcp-snowflake
  traffic:
    jwtAuthentication:
      providers:
        - issuer: solo.io
          jwks:
            inline: '{"keys": [{"kty": "RSA", "kid": "solo-public-key-001", "use": "sig", "alg": "RS256", "n": "vdV2XxH70WcgDKedYXNQ3Dy1LN8LKziw3pxBe0M-QG3_urCbN-oTPL2e0xrj5t2JOV-eBNaII17oZ6z9q84lLzn4mgU_UzP-Efv6iTZLlC_SD30AknifnoX8k38zbJtuwkvVcZvkam0LM5oIwSf4wJVpdPKHb3o_gGRpCBxWdQHPdBWMBPwOeqFfONFrM0bEnShFWf3d87EgckdVcrypelLyUZJ_ACdEGYUhS6FHmyojA1g6zKryAAWsH5Y-UCUuJd7VlOCMoBpAKK0BSdlF3WVSYHDlyMSB5H61eYCXSpfKcGhoHxViLgq6yjUR7TOHkJ-OtWna513TrkRw2Y0hsQ", "e": "AQAB"}]}'
EOF
```

### MCP Traffic Policy

1. Add the traffic policy
```
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: snowflake-mcp-backend
  backend:
    mcp:
      authorization:
        policy:
          matchExpressions:
            - 'mcp.tool.name == ""'
EOF
```

You will now see no tools available in the MCP server

2. Cleanup

```
kubectl delete -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt-rbac
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: snowflake-mcp-backend
  backend:
    mcp:
      authorization:
        policy:
          matchExpressions:
            - 'mcp.tool.name == ""'
EOF
```