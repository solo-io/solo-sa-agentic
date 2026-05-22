SHELL := /bin/bash

CLUSTER_NAME ?= enterprise-mcp-agentgateway
AGW_NAMESPACE ?= agentgateway-system
CLEAN_INSTALL ?= true
LOCAL_PORT ?= 18082

export CLUSTER_NAME AGW_NAMESPACE CLEAN_INSTALL LOCAL_PORT

.PHONY: install install-otel status cleanup help

install:
	./scripts/install-enterprise-kind.sh

install-otel:
	./scripts/install-otel-stack.sh

status:
	kubectl get gatewayclass enterprise-agentgateway
	kubectl -n "$(AGW_NAMESPACE)" get pods,svc,gateway,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy,ratelimitconfig

cleanup:
	kind delete cluster --name "$(CLUSTER_NAME)"

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  install            Clean kind install with Enterprise agentgateway only.' \
	  '  install-otel       Install Loki, Tempo, OTel collector, Prometheus, and Grafana.' \
	  '  status             Show installed Enterprise and enterprise MCP resources.' \
	  '  cleanup            Delete the enterprise MCP kind cluster.' \
	  '' \
	  'Common variables:' \
	  '  CLUSTER_NAME=enterprise-mcp-agentgateway' \
	  '  AGW_NAMESPACE=agentgateway-system' \
	  '  CLEAN_INSTALL=true' \
	  '  LOCAL_PORT=18082'
