#!/usr/bin/env bash
set -Eeuo pipefail

TELEMETRY_NAMESPACE="${TELEMETRY_NAMESPACE:-telemetry}"

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

install_loki() {
  log "Installing Grafana Loki"
  helm upgrade --install loki loki \
    --repo https://grafana.github.io/helm-charts \
    --version 6.24.0 \
    --namespace "$TELEMETRY_NAMESPACE" \
    --create-namespace \
    --values - <<'EOF'
loki:
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: 2024-04-01
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  auth_enabled: false
singleBinary:
  replicas: 1
minio:
  enabled: true
gateway:
  enabled: false
test:
  enabled: false
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
lokiCanary:
  enabled: false
limits_config:
  allow_structured_metadata: true
memberlist:
  service:
    publishNotReadyAddresses: true
deploymentMode: SingleBinary
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomCompactor:
  replicas: 0
bloomGateway:
  replicas: 0
EOF
}

install_tempo() {
  log "Installing Grafana Tempo"
  helm upgrade --install tempo tempo \
    --repo https://grafana.github.io/helm-charts \
    --version 1.16.0 \
    --namespace "$TELEMETRY_NAMESPACE" \
    --create-namespace \
    --values - <<'EOF'
persistence:
  enabled: false
tempo:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
EOF
}

install_otel_collectors() {
  log "Installing OpenTelemetry traces collector"
  helm upgrade --install opentelemetry-collector-traces opentelemetry-collector \
    --repo https://open-telemetry.github.io/opentelemetry-helm-charts \
    --version 0.127.2 \
    --set mode=deployment \
    --set image.repository="otel/opentelemetry-collector-contrib" \
    --set command.name="otelcol-contrib" \
    --namespace="$TELEMETRY_NAMESPACE" \
    --create-namespace \
    -f - <<'EOF'
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  exporters:
    otlp/tempo:
      endpoint: http://tempo.telemetry.svc.cluster.local:4317
      tls:
        insecure: true
    debug:
      verbosity: detailed
  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [batch]
        exporters: [debug, otlp/tempo]
      logs:
        receivers: [otlp]
        processors: [batch]
        exporters: [debug]
EOF
}

install_prometheus_stack() {
  log "Installing kube-prometheus-stack with Grafana"
  helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts \
    --version 75.6.1 \
    --namespace "$TELEMETRY_NAMESPACE" \
    --create-namespace \
    --values - <<'EOF'
alertmanager:
  enabled: false
prometheus:
  prometheusSpec:
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    enableFeatures:
      - native-histograms
    enableRemoteWriteReceiver: true
grafana:
  enabled: true
  defaultDashboardsEnabled: true
  adminPassword: prom-operator
  datasources:
   datasources.yaml:
     apiVersion: 1
     datasources:
      - name: Prometheus
        type: prometheus
        uid: prometheus
        access: proxy
        orgId: 1
        url: http://kube-prometheus-stack-prometheus.telemetry:9090
        basicAuth: false
        editable: true
      - name: Tempo
        type: tempo
        access: proxy
        basicAuth: false
        orgId: 1
        uid: tempo
        url: http://tempo.telemetry.svc.cluster.local:3100
        isDefault: false
        editable: true
      - orgId: 1
        name: Loki
        type: loki
        access: proxy
        url: http://loki.telemetry.svc.cluster.local:3100
        basicAuth: false
        isDefault: false
        editable: true
EOF
}

wait_for_stack() {
  log "Waiting for telemetry deployments"
  kubectl -n "$TELEMETRY_NAMESPACE" rollout status deployment/opentelemetry-collector-traces --timeout=5m
  kubectl -n "$TELEMETRY_NAMESPACE" rollout status deployment/kube-prometheus-stack-grafana --timeout=5m
  kubectl -n "$TELEMETRY_NAMESPACE" rollout status statefulset/loki --timeout=5m
  kubectl -n "$TELEMETRY_NAMESPACE" rollout status statefulset/tempo --timeout=5m
}

main() {
  require_cmd helm
  require_cmd kubectl

  install_loki
  install_tempo
  install_otel_collectors
  install_prometheus_stack
  wait_for_stack

  printf '\nOTEL stack installed. Grafana can be reached with:\n'
  printf 'kubectl -n %s port-forward deployment/kube-prometheus-stack-grafana 3000:3000\n' "$TELEMETRY_NAMESPACE"
}

main "$@"
