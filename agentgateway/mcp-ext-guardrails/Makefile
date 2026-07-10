SHELL := /bin/bash

CLUSTER_NAME ?= mcp-ext-guardrails-agentgateway
AGW_NAMESPACE ?= agentgateway-system
CLEAN_INSTALL ?= true
LOCAL_PORT ?= 18083

export CLUSTER_NAME AGW_NAMESPACE CLEAN_INSTALL LOCAL_PORT

.PHONY: install status port-forward cleanup help

install:
	./scripts/install-enterprise-kind.sh

status:
	kubectl get gatewayclass enterprise-agentgateway
	kubectl -n "$(AGW_NAMESPACE)" get pods,svc,gateway,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy

port-forward:
	@echo "MCP endpoint -> http://localhost:$(LOCAL_PORT)/mcp   (Host: mcp.example.com)"
	kubectl -n "$(AGW_NAMESPACE)" port-forward svc/mcp-ext-guardrails-gateway $(LOCAL_PORT):3000

cleanup:
	kind delete cluster --name "$(CLUSTER_NAME)"

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  install       Clean kind install: Enterprise agentgateway + the ExtMCP guardrails demo.' \
	  '  status        Show installed gateway, routes, backends, and policies.' \
	  '  port-forward  Forward the MCP gateway listener to localhost:$(LOCAL_PORT).' \
	  '  cleanup       Delete the demo kind cluster.' \
	  '' \
	  'Common variables:' \
	  '  CLUSTER_NAME=mcp-ext-guardrails-agentgateway' \
	  '  AGW_NAMESPACE=agentgateway-system' \
	  '  CLEAN_INSTALL=true' \
	  '  LOCAL_PORT=18083' \
	  '' \
	  'Requires: AGENTGATEWAY_LICENSE_KEY, and docker + kubectl + helm + curl.'
