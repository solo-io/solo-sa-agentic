# Dual Agentgateway Kind Bootstrap

This directory contains a local bootstrap script for installing OSS agentgateway
and Solo Enterprise for agentgateway side by side in one kind cluster. It also
deploys an in-cluster OpenAI-compatible mock LLM and configures routing through
both gateways.

## Prerequisites

- Docker
- `kubectl`
- Helm 3
- `curl`
- A Solo Enterprise for agentgateway license key if installing Enterprise

The script installs `kind` automatically if it is not already available.

## Run

From this directory:

```bash
export AGENTGATEWAY_LICENSE_KEY='<license-key>'
./install-dual-agentgateway-kind.sh
```

Or use the Makefile wrapper:

```bash
export AGENTGATEWAY_LICENSE_KEY='<license-key>'
make install
```

From the repository root:

```bash
AGENTGATEWAY_LICENSE_KEY='<license-key>' make -C agentgateway/oss-ent install
```

By default, the script:

- Creates or reuses a kind cluster named `agentgateway-dual`.
- Installs Kubernetes Gateway API CRDs.
- Installs OSS agentgateway in `agentgateway-system`.
- Transfers ownership of the shared `agentgateway.dev` CRDs from the OSS CRD
  Helm release to the Enterprise CRD Helm release.
- Installs Solo Enterprise for agentgateway in `agentgateway-enterprise-system`.
- Deploys the `mock-llm` manifests from `manifests/mock-llm/` into each enabled
  gateway namespace.
- Applies the OSS route manifests from `manifests/oss/` in `agentgateway-system`.
- Applies the Enterprise route manifests from `manifests/enterprise/` in
  `agentgateway-enterprise-system`.
- Runs smoke tests through local port-forwards.

## Manifests

Kubernetes YAML that the script applies is kept in folders by type:

```text
agentgateway/oss-ent/manifests/
  mock-llm/
    deployment.yaml
    service.yaml
  oss/
    gateway.yaml
    backend.yaml
    httproute.yaml
  enterprise/
    gateway.yaml
    backend.yaml
    httproute.yaml
```

When running `./install-dual-agentgateway-kind.sh` or `make` from
`agentgateway/oss-ent`, the script resolves these manifests from the local
`manifests/` directory automatically. From the repository root, use
`make -C agentgateway/oss-ent ...` so the Makefile runs with the expected
working directory.

## Common Overrides

Show available Make targets:

```bash
make help
```

From the repository root:

```bash
make -C agentgateway/oss-ent help
```

Skip Enterprise:

```bash
INSTALL_ENTERPRISE=false ./install-dual-agentgateway-kind.sh
```

Or:

```bash
make install-oss-only
```

Install Enterprise only:

```bash
INSTALL_OSS=false ./install-dual-agentgateway-kind.sh
```

Or:

```bash
make install-enterprise-only
```

From the repository root:

```bash
AGENTGATEWAY_LICENSE_KEY='<license-key>' make -C agentgateway/oss-ent install-enterprise-only
```

Skip smoke tests:

```bash
RUN_SMOKE_TESTS=false ./install-dual-agentgateway-kind.sh
```

Or:

```bash
make install-no-smoke
```

Use a different cluster name:

```bash
CLUSTER_NAME=my-agentgateway ./install-dual-agentgateway-kind.sh
```

Or:

```bash
make install CLUSTER_NAME=my-agentgateway
```

Use different namespaces:

```bash
OSS_AGW_NAMESPACE=agentgateway-system \
ENT_AGW_NAMESPACE=agentgateway-enterprise-system \
./install-dual-agentgateway-kind.sh
```

Pin chart versions:

```bash
OSS_AGENTGATEWAY_VERSION=v1.1.0 \
ENT_AGENTGATEWAY_VERSION=v2026.5.0-beta.3 \
./install-dual-agentgateway-kind.sh
```

Use a specific kind node image:

```bash
KIND_NODE_IMAGE='kindest/node:v1.35.0' ./install-dual-agentgateway-kind.sh
```

## OSS to Enterprise CRD Ownership

OSS agentgateway and Solo Enterprise for agentgateway use the same
`agentgateway.dev` CRDs. If OSS agentgateway is already installed, those CRDs
are usually owned by the OSS Helm release, commonly `agentgateway-crds`.

When you later install the Enterprise CRD chart, Helm might fail with an error
like:

```text
CustomResourceDefinition "agentgatewaybackends.agentgateway.dev" in namespace "" exists and cannot be imported into the current release: invalid ownership metadata; annotation validation error: key "meta.helm.sh/release-name" must equal "enterprise-agentgateway-crds": current value is "agentgateway-crds"
```

The required transition is to move Helm ownership of the shared
`agentgateway.dev` CRDs to the Enterprise CRD release before installing the
Enterprise CRD chart. The script does this automatically when Enterprise install
is enabled.

Standalone command:

```bash
for crd in $(kubectl get crd \
  -o jsonpath='{range .items[?(@.spec.group=="agentgateway.dev")]}{.metadata.name}{"\n"}{end}'); do
  kubectl annotate crd "$crd" \
    meta.helm.sh/release-name=enterprise-agentgateway-crds \
    meta.helm.sh/release-namespace=agentgateway-enterprise-system \
    --overwrite
  kubectl label crd "$crd" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite
done
```

Then install the Enterprise CRD chart:

```bash
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace \
  --namespace agentgateway-enterprise-system \
  --version v2026.5.0-beta.3
```

This does not delete the CRDs or the existing custom resources. It only changes
the Helm release metadata that controls which Helm release is allowed to manage
the CRD objects.

## Enterprise GatewayClass

OSS agentgateway creates its `agentgateway` GatewayClass from the OSS CRD chart.
Solo Enterprise for agentgateway creates its `enterprise-agentgateway`
GatewayClass from the Enterprise controller chart. The script does not create
either GatewayClass manually.

After the Enterprise controller install, verify it with:

```bash
kubectl get gatewayclass enterprise-agentgateway
```

## Test Manually

Port-forward the OSS gateway:

```bash
kubectl -n agentgateway-system port-forward service/oss-agentgateway-proxy 18080:80
```

Send a request:

```bash
curl http://127.0.0.1:18080/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer local-dev' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello oss"}]}'
```

Port-forward the Enterprise gateway:

```bash
kubectl -n agentgateway-enterprise-system port-forward service/enterprise-agentgateway-proxy 18081:80
```

Send a request:

```bash
curl http://127.0.0.1:18081/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer local-dev' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello enterprise"}]}'
```

## Inspect Resources

```bash
kubectl -n agentgateway-system get pods,svc,gateway,httproute,agentgatewaybackend
kubectl -n agentgateway-enterprise-system get pods,svc,gateway,httproute,agentgatewaybackend
kubectl get gatewayclass
```

Or:

```bash
make status
```

From the repository root:

```bash
make -C agentgateway/oss-ent status
```

## Cleanup

Delete the kind cluster:

```bash
kind delete cluster --name agentgateway-dual
```

Or:

```bash
make cleanup
```

From the repository root:

```bash
make -C agentgateway/oss-ent cleanup
```
