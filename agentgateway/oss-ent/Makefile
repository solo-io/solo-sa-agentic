SHELL := /bin/bash

SCRIPT := ./install-dual-agentgateway-kind.sh
CLUSTER_NAME ?= agentgateway-dual
OSS_AGW_NAMESPACE ?= agentgateway-system
ENT_AGW_NAMESPACE ?= agentgateway-enterprise-system
OSS_LOCAL_PORT ?= 18080
ENT_LOCAL_PORT ?= 18081
INSTALL_OSS ?= true
INSTALL_ENTERPRISE ?= true
RUN_SMOKE_TESTS ?= true
KIND_VERSION ?= v0.30.0
KIND_INSTALL_DIR ?= $(HOME)/.local/bin
KIND_NODE_IMAGE ?=
GATEWAY_API_VERSION ?= v1.5.0
OSS_AGENTGATEWAY_VERSION ?= v1.1.0
OSS_AGENTGATEWAY_CRDS_CHART ?= oci://cr.agentgateway.dev/charts/agentgateway-crds
OSS_AGENTGATEWAY_CHART ?= oci://cr.agentgateway.dev/charts/agentgateway
ENT_AGENTGATEWAY_VERSION ?= v2026.5.0-beta.3
ENT_AGENTGATEWAY_CRDS_RELEASE ?= enterprise-agentgateway-crds
ENT_AGENTGATEWAY_CRDS_CHART ?= oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds
ENT_AGENTGATEWAY_CHART ?= oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway

export CLUSTER_NAME OSS_AGW_NAMESPACE ENT_AGW_NAMESPACE OSS_LOCAL_PORT ENT_LOCAL_PORT
export INSTALL_OSS INSTALL_ENTERPRISE RUN_SMOKE_TESTS
export KIND_VERSION KIND_INSTALL_DIR KIND_NODE_IMAGE
export GATEWAY_API_VERSION
export OSS_AGENTGATEWAY_VERSION OSS_AGENTGATEWAY_CRDS_CHART OSS_AGENTGATEWAY_CHART
export ENT_AGENTGATEWAY_VERSION ENT_AGENTGATEWAY_CRDS_RELEASE ENT_AGENTGATEWAY_CRDS_CHART ENT_AGENTGATEWAY_CHART

.PHONY: install install-oss-only install-enterprise-only install-no-smoke smoke-test status cleanup help

install:
	$(SCRIPT)

install-oss-only:
	INSTALL_ENTERPRISE=false \
	$(SCRIPT)

install-enterprise-only:
	INSTALL_OSS=false \
	$(SCRIPT)

install-no-smoke:
	RUN_SMOKE_TESTS=false \
	$(SCRIPT)

smoke-test:
	kubectl -n "$(OSS_AGW_NAMESPACE)" port-forward service/oss-agentgateway-proxy "$(OSS_LOCAL_PORT):80" >/tmp/oss-agentgateway-port-forward.log 2>&1 & \
	oss_pid="$$!"; \
	trap 'kill "$$oss_pid" >/dev/null 2>&1 || true' EXIT; \
	until grep -q 'Forwarding from' /tmp/oss-agentgateway-port-forward.log; do sleep 1; done; \
	curl -fsS "http://127.0.0.1:$(OSS_LOCAL_PORT)/v1/chat/completions" \
	  -H 'content-type: application/json' \
	  -H 'authorization: Bearer local-dev' \
	  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello oss"}]}'; \
	echo
	kubectl -n "$(ENT_AGW_NAMESPACE)" port-forward service/enterprise-agentgateway-proxy "$(ENT_LOCAL_PORT):80" >/tmp/enterprise-agentgateway-port-forward.log 2>&1 & \
	ent_pid="$$!"; \
	trap 'kill "$$ent_pid" >/dev/null 2>&1 || true' EXIT; \
	until grep -q 'Forwarding from' /tmp/enterprise-agentgateway-port-forward.log; do sleep 1; done; \
	curl -fsS "http://127.0.0.1:$(ENT_LOCAL_PORT)/v1/chat/completions" \
	  -H 'content-type: application/json' \
	  -H 'authorization: Bearer local-dev' \
	  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello enterprise"}]}'; \
	echo

status:
	kubectl -n "$(OSS_AGW_NAMESPACE)" get pods,svc,gateway,httproute,agentgatewaybackend || true
	kubectl -n "$(ENT_AGW_NAMESPACE)" get pods,svc,gateway,httproute,agentgatewaybackend || true
	kubectl get gatewayclass

cleanup:
	kind delete cluster --name "$(CLUSTER_NAME)"

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  install           Install OSS and Enterprise agentgateway, routes, mock LLM, and run smoke tests.' \
	  '  install-oss-only  Install only OSS agentgateway, route, mock LLM, and run smoke tests.' \
	  '  install-enterprise-only  Install only Enterprise agentgateway, route, mock LLM, and run smoke tests.' \
	  '  install-no-smoke  Install OSS and Enterprise but skip smoke tests.' \
	  '  smoke-test        Run curl smoke tests through both gateways.' \
	  '  status            Show agentgateway resources.' \
	  '  cleanup           Delete the kind cluster.' \
	  '' \
	  'Common variables:' \
	  '  CLUSTER_NAME=agentgateway-dual' \
	  '  OSS_AGW_NAMESPACE=agentgateway-system' \
	  '  ENT_AGW_NAMESPACE=agentgateway-enterprise-system' \
	  '  OSS_LOCAL_PORT=18080' \
	  '  ENT_LOCAL_PORT=18081'
