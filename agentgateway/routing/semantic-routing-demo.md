# Semantic Model Routing With Enterprise Agentgateway

Route LLM traffic to the *right* model per request using enterprise agentgateway on Kubernetes: expensive frontier models (Claude Opus 4.8, GPT-5.5) only when the request actually needs them, a cheaper default (Claude Sonnet 5) for everything else. Clients call one stable endpoint; the gateway classifies the request and picks the concrete model.

Enterprise agentgateway does not ship a first-party embedding-based semantic classifier. What it ships is the routing machinery:

- **`EnterpriseAgentgatewayBackend`** with an `ai` spec: one backend per model, or **priority groups** for health-based failover.
- **`HTTPRoute`**: weighted splits and header-based routing across AI backends.
- **`EnterpriseAgentgatewayPolicy`** with **`phase: PreRouting`**: transformation (CEL) or `extProc` that runs *before* route selection, so a derived intent header can drive the routing decision.

The pattern: a PreRouting policy classifies the request and sets `x-intent`; the HTTPRoute matches on `x-intent` and steers to the right model backend. Swap the CEL classifier for an `extProc` server and the same wiring becomes true semantic routing.x

## Quick Vocab

- **`EnterpriseAgentgatewayBackend`** (`enterpriseagentgateway.solo.io/v1alpha1`): a backend definition. For LLMs, `spec.ai.provider.<anthropic|openai|gemini|bedrock|...>` with optional `model` override; `spec.policies.auth.secretRef` for credentials. `spec.ai.groups` instead of `provider` gives priority-ordered provider groups. The `ai` spec is identical to the OSS `AgentgatewayBackend`; the enterprise kind additionally supports `entMcp` backends and `tokenExchange`/`workloadIdentity` backend auth.
- **`EnterpriseAgentgatewayPolicy`** (`enterpriseagentgateway.solo.io/v1alpha1`): attaches traffic policies to a Gateway/route. `spec.traffic.phase: PreRouting` runs the policy before route selection (default is `PostRouting`).
- **Transformation**: `spec.traffic.transformation.request.set` sets request headers from CEL expressions (request headers, JWT claims, or the request body via `json(request.body)`).
- **Priority groups**: within a group, providers are weighted automatically by health; if a whole group degrades, traffic shifts to the next group.

## Prerequisites

- A cluster running Solo Enterprise for Agentgateway (this was built against `enterprise-agentgateway` v2026.6.3):

```bash
kubectl get gatewayclass enterprise-agentgateway
kubectl get crd enterpriseagentgatewaybackends.enterpriseagentgateway.solo.io enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io
```

- An Anthropic API key and an OpenAI API key
- `curl` and `jq`

## Step 1: Namespace and provider secrets

The default Secret resolver requires the API key under the `Authorization` key. Export the keys as environment variables and create the Secrets imperatively so keys never land in a manifest file in plain text:

```bash
export ANTHROPIC_API_KEY='<your-anthropic-key>'
export OPENAI_API_KEY='<your-openai-key>'

kubectl create ns semantic-routing
kubectl create secret generic anthropic-secret -n semantic-routing \
  --from-literal=Authorization="$ANTHROPIC_API_KEY"
kubectl create secret generic openai-secret -n semantic-routing \
  --from-literal=Authorization="$OPENAI_API_KEY"
```

## Step 2: Model backends

One `EnterpriseAgentgatewayBackend` per model tier, plus one failover backend using priority groups. The tiers:

| Backend | Model | Role |
|---|---|---|
| `claude-opus` | `claude-opus-4-8` | expensive; only for requests that need it (code) |
| `gpt-5-5` | `gpt-5.5` | expensive; deep reasoning |
| `claude-sonnet` | `claude-sonnet-5` | cheaper default for everything else |
| `gpt-5-mini` | `gpt-5-mini` | cheap OpenAI tier; weighted split and failover fallback |

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: claude-opus
  namespace: semantic-routing
spec:
  ai:
    provider:
      anthropic:
        model: claude-opus-4-8
  policies:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: claude-sonnet
  namespace: semantic-routing
spec:
  ai:
    provider:
      anthropic:
        model: claude-sonnet-5
  policies:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: gpt-5-5
  namespace: semantic-routing
spec:
  ai:
    provider:
      openai:
        model: gpt-5.5
  policies:
    auth:
      secretRef:
        name: openai-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: gpt-5-mini
  namespace: semantic-routing
spec:
  ai:
    provider:
      openai:
        model: gpt-5-mini
  policies:
    auth:
      secretRef:
        name: openai-secret
---
# Failover: group order = priority. If every provider in the first group is
# degraded, traffic shifts to the next group. Within a group, providers are
# weighted automatically by health.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: resilient-failover
  namespace: semantic-routing
spec:
  ai:
    groups:
    - providers:
      - name: primary-claude-sonnet
        anthropic:
          model: claude-sonnet-5
    - providers:
      - name: fallback-gpt-5-mini
        openai:
          model: gpt-5-mini
---
# Per-provider auth for the failover backend, attached by provider name via
# targetRefs[].sectionName. Note: enterprise-agentgateway v2026.6.3 rejects
# inline ai.groups[].providers[].policies.auth (a CRD validation rule that
# predates the auth field); newer versions accept it inline.
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: resilient-failover-anthropic-auth
  namespace: semantic-routing
spec:
  targetRefs:
  - group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayBackend
    name: resilient-failover
    sectionName: primary-claude-sonnet
  backend:
    auth:
      secretRef:
        name: anthropic-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: resilient-failover-openai-auth
  namespace: semantic-routing
spec:
  targetRefs:
  - group: enterpriseagentgateway.solo.io
    kind: EnterpriseAgentgatewayBackend
    name: resilient-failover
    sectionName: fallback-gpt-5-mini
  backend:
    auth:
      secretRef:
        name: openai-secret
EOF
```

The `model` field on the provider overrides whatever model the client sends. The backend *is* the model choice, which is what lets the route decide.

## Step 3: Gateway and routes

Three "virtual models", one hostname each:

| Hostname | Behavior |
|---|---|
| `smart.demo.internal` | intent-based: `x-intent: code` → claude-opus-4-8, `x-intent: deep-reasoning` → gpt-5.5, default → claude-sonnet-5 (cheaper) |
| `fast.demo.internal` | weighted 80/20 split: claude-sonnet-5 / gpt-5-mini |
| `resilient.demo.internal` | priority-group failover backend |

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: semantic-routing
  namespace: semantic-routing
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - name: http
    protocol: HTTP
    port: 8080
    allowedRoutes:
      namespaces:
        from: Same
---
# "smart": intent-based routing. x-intent is set by the PreRouting policy in
# Step 4 before this route match is evaluated.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: smart
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - smart.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
      headers:
      - name: x-intent
        value: code
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-opus
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
      headers:
      - name: x-intent
        value: deep-reasoning
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: gpt-5-5
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-sonnet
---
# "fast": weighted split across two cheap models.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fast
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - fast.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: claude-sonnet
      weight: 80
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: gpt-5-mini
      weight: 20
---
# "resilient": health-based failover via the priority-group backend.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: resilient
  namespace: semantic-routing
spec:
  parentRefs:
  - name: semantic-routing
  hostnames:
  - resilient.demo.internal
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/chat/completions
    backendRefs:
    - group: enterpriseagentgateway.solo.io
      kind: EnterpriseAgentgatewayBackend
      name: resilient-failover
EOF
```

## Step 4: PreRouting intent classifier

This is the piece that makes it "semantic". `phase: PreRouting` runs the transformation *before* the HTTPRoute match, so the header it sets participates in routing. The CEL below respects a client-supplied `x-intent` and otherwise derives intent from the prompt content:

```bash
kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: intent-classifier
  namespace: semantic-routing
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: semantic-routing
  traffic:
    phase: PreRouting
    transformation:
      request:
        set:
        - name: x-intent
          value: >-
            "x-intent" in request.headers ? request.headers["x-intent"] :
            (json(request.body).messages.exists(m, m.content.contains("code") || m.content.contains("function")) ? "code" :
            (json(request.body).messages.exists(m, m.content.contains("prove") || m.content.contains("theorem")) ? "deep-reasoning" : "general"))
EOF
```

Keyword CEL is deliberately simple; it's a stand-in for the classifier. The same PreRouting slot accepts an `extProc` policy instead, which is how you plug in a real semantic classifier (see [the ladder](#from-keyword-cel-to-true-semantic-routing)).

This mirrors the pattern enterprise agentgateway uses in its own e2e suite: a PreRouting policy sets a header from a JWT claim (`jwt.tier`) and the HTTPRoute routes premium users to a different backend (`ent-controller/test/e2e/features/agentgateway/policies/testdata/jwt-transform-routing-policy.yaml`).

## Step 5: Verify status

```bash
kubectl get enterpriseagentgatewaybackends,httproutes,gateway -n semantic-routing
kubectl get enterpriseagentgatewaypolicies -n semantic-routing
```

Expect every backend `ACCEPTED: True`, the Gateway `PROGRAMMED: True` (a proxy pod and a LoadBalancer Service appear in the namespace), and all three policies (`intent-classifier` plus the two failover auth policies) `ACCEPTED: True / ATTACHED: True`.

## Step 6: Send traffic

Port-forward (or use the LoadBalancer address once assigned):

```bash
kubectl port-forward -n semantic-routing svc/semantic-routing 8080:8080 &
```

Intent-based routing: same endpoint, different models.

- Explicit intent header: escalates to the expensive model -> claude-opus-4-8
- No header; the PreRouting CEL classifier detects "prove" -> gpt-5.5
- Generic prompt: stays on the cheaper default -> claude-sonnet-5
```bash

curl -s http://35.229.54.135:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -H 'x-intent: code' \
  -d '{"model":"any","messages":[{"role":"user","content":"write a binary search in Go"}]}' | jq -r .model

curl -s http://35.229.54.135:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"prove sqrt(2) is irrational"}]}' | jq -r .model

curl -s http://35.229.54.135:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"say hi"}]}' | jq -r .model
```

The response `model` field shows the concrete model that served the request (the backend's `model` override wins regardless of what the client sent).

Weighted split (~80/20 over 10 calls):

```bash
for i in $(seq 1 10); do
  curl -s http://35.229.54.135:8080/v1/chat/completions \
    -H 'Host: fast.demo.internal' -H 'content-type: application/json' \
    -d '{"model":"any","messages":[{"role":"user","content":"hi"}]}' | jq -r .model
done | sort | uniq -c
```

Failover serves from `claude-sonnet-5` (priority group 0) while healthy, shifting to `gpt-5-mini` if Anthropic degrades:

```bash
curl -s http://35.229.54.135:8080/v1/chat/completions \
  -H 'Host: resilient.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"hi"}]}' | jq -r .model
```

## From Keyword CEL To True Semantic Routing

Three rungs, all using the same HTTPRoute wiring; only the classifier changes:

1. **Client-declared intent**: the app sends `x-intent` itself. Zero gateway logic; you trust the caller.
2. **Gateway CEL heuristics** (this demo): PreRouting transformation derives `x-intent` from headers, JWT claims, or `json(request.body)`. Deterministic, no extra hops, limited semantics.
3. **External classifier via `extProc`** (built below): replace `transformation` with `extProc` in the same PreRouting policy, pointing at a gRPC classifier service. The processor inspects the prompt, sets `x-intent`, and route matching proceeds on the mutated request. Enterprise WAF is built on this exact hook, and `extProc` also supports CEL-conditional execution (`conditional` entries) to run different classifiers for different traffic.

The rest of this section builds rung 3 end to end: a small Go ext_proc classifier, deployed next to the gateway, wired in with a PreRouting `extProc` policy. The classifier here scores regex signals (a stand-in you can demo anywhere); `classify()` is the single function you swap for an embedding model, and the vLLM Semantic Router speaks the same ext_proc protocol if you want a production drop-in.

### Rung 3a: the classifier

The server implements Envoy's `ext_proc` v3 protocol: agentgateway streams it the request headers and (buffered) body, and it answers the body phase with a header mutation that sets `x-intent`.

```bash
mkdir -p semantic-classifier && cd semantic-classifier

cat <<'EOF' > main.go
// semantic-classifier: an Envoy ext_proc gRPC server that classifies the
// intent of an OpenAI-style chat request and sets an x-intent header that
// agentgateway routes on. Swap classify() for a real embedding model (or
// point the gateway at vLLM Semantic Router) without touching the wiring.
package main

import (
	"encoding/json"
	"io"
	"log"
	"net"
	"regexp"
	"strings"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extprocv3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
)

var (
	codeRe = regexp.MustCompile(`(?i)(stack trace|traceback|exception|error:|segfault|debug|refactor|unit test|regex|compile|null pointer|func |def |class |` + "```" + `)`)
	reasonRe = regexp.MustCompile(`(?i)(prove|theorem|derive|step[- ]by[- ]step|formal|trade-?offs?|from first principles)`)
)

type chatRequest struct {
	Messages []struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
}

// classify returns the intent for a chat-completions request body.
// This is the swappable part: replace with an embedding lookup or a
// small classification model for true semantic routing.
func classify(body []byte) string {
	text := string(body)
	var req chatRequest
	if err := json.Unmarshal(body, &req); err == nil && len(req.Messages) > 0 {
		var parts []string
		for _, m := range req.Messages {
			if m.Role != "user" {
				continue
			}
			var s string
			if err := json.Unmarshal(m.Content, &s); err == nil {
				parts = append(parts, s)
			}
		}
		if len(parts) > 0 {
			text = strings.Join(parts, "\n")
		}
	}
	switch {
	case codeRe.MatchString(text):
		return "code"
	case reasonRe.MatchString(text):
		return "deep-reasoning"
	default:
		return "general"
	}
}

type server struct{}

func (s *server) Process(stream extprocv3.ExternalProcessor_ProcessServer) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		var resp *extprocv3.ProcessingResponse
		switch v := req.Request.(type) {
		case *extprocv3.ProcessingRequest_RequestBody:
			intent := classify(v.RequestBody.GetBody())
			log.Printf("classified request as %q", intent)
			resp = &extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_RequestBody{
					RequestBody: &extprocv3.BodyResponse{
						Response: &extprocv3.CommonResponse{
							HeaderMutation: &extprocv3.HeaderMutation{
								SetHeaders: []*corev3.HeaderValueOption{{
									Header: &corev3.HeaderValue{
										Key:      "x-intent",
										RawValue: []byte(intent),
									},
									AppendAction: corev3.HeaderValueOption_OVERWRITE_IF_EXISTS_OR_ADD,
								}},
							},
						},
					},
				},
			}
		case *extprocv3.ProcessingRequest_RequestHeaders:
			resp = &extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_RequestHeaders{
					RequestHeaders: &extprocv3.HeadersResponse{},
				},
			}
		case *extprocv3.ProcessingRequest_ResponseHeaders:
			resp = &extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_ResponseHeaders{
					ResponseHeaders: &extprocv3.HeadersResponse{},
				},
			}
		case *extprocv3.ProcessingRequest_ResponseBody:
			resp = &extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_ResponseBody{
					ResponseBody: &extprocv3.BodyResponse{},
				},
			}
		default:
			continue
		}

		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

func main() {
	lis, err := net.Listen("tcp", ":9000")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	grpcServer := grpc.NewServer()
	extprocv3.RegisterExternalProcessorServer(grpcServer, &server{})
	log.Println("semantic-classifier listening on :9000")
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
EOF

cat <<'EOF' > Dockerfile
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /semantic-classifier .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /semantic-classifier /semantic-classifier
EXPOSE 9000
ENTRYPOINT ["/semantic-classifier"]
EOF
```

(Verified with `github.com/envoyproxy/go-control-plane/envoy` v1.37.0 and `google.golang.org/grpc` v1.82.0; `go mod tidy` pins them in `go.sum`.)

### Rung 3b: build and push

Push to any registry the cluster can pull from (GAR/ECR/ghcr):

```bash
export IMAGE='<your-registry>/semantic-classifier:0.1.0'

go mod init semantic-classifier
go mod tidy
go build .          # sanity check before the image build

docker build -t "$IMAGE" .
docker push "$IMAGE"
```

### Rung 3c: deploy the classifier

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: semantic-classifier
  namespace: semantic-routing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: semantic-classifier
  template:
    metadata:
      labels:
        app: semantic-classifier
    spec:
      containers:
      - name: classifier
        image: ${IMAGE}
        ports:
        - containerPort: 9000
        readinessProbe:
          tcpSocket:
            port: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: semantic-classifier
  namespace: semantic-routing
spec:
  selector:
    app: semantic-classifier
  ports:
  - name: grpc
    port: 9000
    targetPort: 9000
    appProtocol: grpc
EOF
```

### Rung 3d: swap the CEL policy for extProc

Remove the CEL classifier so the two PreRouting policies don't fight over `x-intent`, then attach the extProc policy. `requestBodyMode: Buffered` makes agentgateway send the full request body before route selection, which is what lets the classifier see the prompt:

```bash
kubectl delete enterpriseagentgatewaypolicy intent-classifier -n semantic-routing

kubectl apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: semantic-classifier
  namespace: semantic-routing
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: semantic-routing
  traffic:
    phase: PreRouting
    extProc:
      backendRef:
        name: semantic-classifier
        port: 9000
      processingOptions:
        requestBodyMode: Buffered
        responseBodyMode: None
        responseHeaderMode: Skip
EOF
```

The HTTPRoutes from Step 3 are untouched; only who sets `x-intent` changed.

### Rung 3e: prove it beats keyword CEL

This prompt contains none of the CEL keywords (`code`, `function`, `prove`, `theorem`), so rung 2 would have sent it to the cheap default. The classifier recognizes `stack trace` and escalates it to `claude-opus-4-8`:

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Host: smart.demo.internal' -H 'content-type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"why does my app keep crashing? here is the stack trace"}]}' | jq -r .model
```

Watch the classification decisions live:

```bash
kubectl logs -n semantic-routing deploy/semantic-classifier -f
# classified request as "code"
```

## Cleanup

```bash
kubectl delete namespace semantic-routing
```

This removes the Gateway (and its LoadBalancer), all backends, routes, policies, and secrets.

## Source References (agentgateway-enterprise repo)

| What | Where |
|---|---|
| `EnterpriseAgentgatewayBackend` spec (embeds the upstream `AIBackend`) | `ent-controller/api/v1alpha1/enterpriseagentgateway/enterprise_agentgateway_backend_types.go` (~line 46) |
| AI spec, priority groups, `NamedLLMProvider` (upstream types) | `controller/api/v1alpha1/agentgateway/agentgateway_backend_types.go` (~lines 150–260) |
| Backend auth (`secretRef` under `Authorization` key) | `controller/api/v1alpha1/agentgateway/agentgateway_policy_types.go` (`BackendAuth`, ~line 1308) |
| `PreRouting` phase + allowed policies (transformation, extProc, …) | `ent-controller/api/v1alpha1/enterpriseagentgateway/enterprise_agentgateway_policy_types.go` (~line 614) |
| PreRouting transform-then-route e2e example | `ent-controller/test/e2e/features/agentgateway/policies/testdata/jwt-transform-routing-policy.yaml` |
| AI backend + HTTPRoute e2e example | `ent-controller/test/e2e/features/agentgateway/budget/testdata/setup.yaml` |
| ext_proc data-plane implementation | `crates/agentgateway/src/http/ext_proc.rs` |
| PreRouting runs before route selection | `crates/agentgateway/src/proxy/httpproxy.rs` (gateway policies ~841, route selection ~855) |
| Virtual models = standalone-only (XDS sets no model router) | `crates/agentgateway/src/types/agent_xds.rs` (~line 1346) |
