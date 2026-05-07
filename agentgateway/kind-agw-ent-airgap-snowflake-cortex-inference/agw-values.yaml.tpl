tokenExchange:
  enabled: false
  issuer: "enterprise-agentgateway.${AGW_NAMESPACE}.svc.cluster.local:7777"
  tokenExpiration: "1m"
  database:
    type: postgres
    postgres:
      url: "${PG_URL}"
  subjectValidator:
    validatorType: remote
    remoteConfig:
      url: "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys"
  actorValidator:
    validatorType: k8s
  apiValidator:
    validatorType: k8s
  oauthIssuer:
    existingSecretName: agentgateway-oauth-issuer-config
    existingSecretKey: KGW_OAUTH_ISSUER_CONFIG
