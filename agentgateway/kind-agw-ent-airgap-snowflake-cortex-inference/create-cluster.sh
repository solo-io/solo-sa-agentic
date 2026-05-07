#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "==> Creating Kind cluster: ${CLUSTER_NAME}"

kind create cluster \
  --name "${CLUSTER_NAME}" \
  --image "${KIND_IMAGE}" \
  --config "${SCRIPT_DIR}/kind-config.yaml"

echo "==> Cluster created. Context: ${CONTEXT}"
kubectl --context "${CONTEXT}" cluster-info

# --- Private registry: DNS + TLS trust for Harbor ---
# Kind nodes run in Docker and cannot resolve harbor.servebeer.com (resolves
# to 127.0.0.1 on the host). We point it at the Docker bridge gateway IP
# so containerd inside the nodes can reach Harbor.

DOCKER_BRIDGE_IP=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')
echo "==> Configuring Harbor private registry (${HARBOR_REGISTRY} → ${DOCKER_BRIDGE_IP})"

NODES=($(kind get nodes --name "${CLUSTER_NAME}"))
for node in "${NODES[@]}"; do
  # 1) DNS: add hosts entry so harbor.servebeer.com resolves to the Docker bridge
  if ! docker exec "$node" grep -q "${HARBOR_REGISTRY}" /etc/hosts 2>/dev/null; then
    docker exec "$node" sh -c "echo '${DOCKER_BRIDGE_IP} ${HARBOR_REGISTRY}' >> /etc/hosts"
  fi

  # 2) TLS: copy CA cert and create containerd hosts.toml
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/${HARBOR_REGISTRY}"
  docker cp "${HARBOR_CA_CERT}" "$node:/etc/containerd/certs.d/${HARBOR_REGISTRY}/ca.crt"

  docker exec "$node" sh -c "cat > /etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml <<TOML
server = \"https://${HARBOR_REGISTRY}\"

[host.\"https://${HARBOR_REGISTRY}\"]
  capabilities = [\"pull\", \"resolve\"]
  ca = \"/etc/containerd/certs.d/${HARBOR_REGISTRY}/ca.crt\"
TOML"

  # 3) Enable containerd registry config_path if not already set
  if ! docker exec "$node" grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
    docker exec "$node" sh -c 'cat >> /etc/containerd/config.toml <<CONF

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
CONF'
  fi

  # 4) Restart containerd to pick up the new config
  docker exec "$node" systemctl restart containerd
  echo "    ${node}: DNS + TLS configured"
done

echo "==> Harbor registry setup complete — nodes can pull from ${HARBOR_REGISTRY}"
