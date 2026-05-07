# Private Registry Setup — AGW Enterprise

Mirror Solo Enterprise for AgentGateway images to your private registry for air-gapped or private-registry deployments. All registry URLs and versions are read from `../env.sh` — update that file to change the target registry or versions.

## Configuration

All values come from `env.sh`:

| Variable | Purpose |
|----------|---------|
| `HARBOR_REGISTRY` | Private registry hostname |
| `HARBOR_PROJECT` | Registry project/namespace |
| `AGW_VERSION` | AgentGateway version |
| `EXTAUTH_VERSION` | ExtAuth sidecar version |
| `RATELIMITER_VERSION` | Rate limiter sidecar version |
| `REDIS_VERSION` | Redis (ext-cache) version |
| `AGW_HELM_REGISTRY` | OCI path for Helm charts |

## Image Inventory

### AGW Core Images

| Component | Source Image | Private Registry Image |
|-----------|-------------|------------------------|
| Controller | `us-docker.pkg.dev/solo-public/enterprise-agentgateway/enterprise-agentgateway-controller:${AGW_VERSION}` | `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/enterprise-agentgateway-controller:${AGW_VERSION}` |
| Proxy | `us-docker.pkg.dev/solo-public/enterprise-agentgateway/agentgateway-enterprise:${AGW_VERSION}` | `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/agentgateway-enterprise:${AGW_VERSION}` |

### Shared Sidecar Images

| Component | Source Image | Private Registry Image |
|-----------|-------------|------------------------|
| ExtAuth | `gcr.io/gloo-mesh/ext-auth-service:${EXTAUTH_VERSION}` | `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/ext-auth-service:${EXTAUTH_VERSION}` |
| Rate Limiter | `gcr.io/gloo-mesh/rate-limiter:${RATELIMITER_VERSION}` | `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/rate-limiter:${RATELIMITER_VERSION}` |
| Redis (ext-cache) | `docker.io/redis:${REDIS_VERSION}` | `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/redis:${REDIS_VERSION}` |

### Helm Charts

| Chart | Source | Private Registry |
|-------|--------|------------------|
| CRDs | `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds` | `${AGW_HELM_REGISTRY}/enterprise-agentgateway-crds` |
| Main | `oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway` | `${AGW_HELM_REGISTRY}/enterprise-agentgateway` |

## Step 1: Login to Private Registry

```bash
source ../env.sh
docker login ${HARBOR_REGISTRY}
helm registry login ${HARBOR_REGISTRY}
```

## Step 2: Mirror Images

Run the mirror script (pulls, tags, pushes all images + helm charts):

```bash
./mirror-images.sh                     # version from env.sh
./mirror-images.sh 2026.5.0-beta.2     # specific version override
```

## Step 3: Manual Steps (if script fails on helm push)

```bash
source ../env.sh

# Pull charts locally
helm pull oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds --version v${AGW_VERSION}
helm pull oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway --version v${AGW_VERSION}

# Push to private registry
helm push enterprise-agentgateway-crds-v${AGW_VERSION}.tgz ${AGW_HELM_REGISTRY}
helm push enterprise-agentgateway-v${AGW_VERSION}.tgz ${AGW_HELM_REGISTRY}
```

## Step 4: Install from Private Registry

See `../env.sh` for the full environment config. The install script (`../install.sh`) reads `AGW_HELM_REGISTRY` for helm installs and sets all image references via `EnterpriseAgentgatewayParameters`.

## Step 5: Configure Kind Cluster for Private Registry

If the private registry uses a self-signed cert, Kind nodes need the CA. The `create-cluster.sh` script handles this automatically by:

1. Adding a `/etc/hosts` entry on each Kind node pointing `${HARBOR_REGISTRY}` to the Docker bridge IP
2. Copying the CA cert to `/etc/containerd/certs.d/${HARBOR_REGISTRY}/ca.crt`
3. Creating a `hosts.toml` for containerd
4. Restarting containerd

If the registry has a valid public cert, create an image pull secret instead:

```bash
source ../env.sh
kubectl create secret docker-registry harbor-creds \
  --docker-server=${HARBOR_REGISTRY} \
  --docker-username=<user> \
  --docker-password=<password> \
  -n ${AGW_NAMESPACE}
```

## Updating Images for New Versions

1. Update `AGW_VERSION`, `EXTAUTH_VERSION`, `RATELIMITER_VERSION`, or `REDIS_VERSION` in `env.sh`
2. Run `./mirror-images.sh`

Find current sidecar versions from a running cluster:

```bash
kubectl get deploy -n ${AGW_NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```
