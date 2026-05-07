#!/usr/bin/env zsh
# Central configuration for the AGW Enterprise demo environment.
# Source this file before running any scripts.

export CLUSTER_NAME="${CLUSTER_NAME:-agw-sq-example}"
export CONTEXT="kind-${CLUSTER_NAME}"
export AGW_VERSION="${AGW_VERSION:-2.3.3}"
export AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
export KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.31.4@sha256:2cb39f7295fe7eafee0842b1052a599a4fb0f8bcf3f83d96c7f4864c357c6c30}"

# --- Private Registry (Harbor) ---
export HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.servebeer.com}"
export HARBOR_PROJECT="${HARBOR_PROJECT:-agentgateway}"

# Harbor CA cert (self-signed) — needed for Kind nodes to pull images
export HARBOR_CA_CERT="${HARBOR_CA_CERT:-/etc/docker/certs.d/${HARBOR_REGISTRY}/ca.crt}"

# Helm charts from Harbor
export AGW_HELM_REGISTRY="${AGW_HELM_REGISTRY:-oci://${HARBOR_REGISTRY}/${HARBOR_PROJECT}/charts}"

# Image versions
export EXTAUTH_VERSION="${EXTAUTH_VERSION:-0.79.1}"
export RATELIMITER_VERSION="${RATELIMITER_VERSION:-0.18.2}"
export REDIS_VERSION="${REDIS_VERSION:-7.2.13-alpine}"

# Gateway hostname and TLS
export GATEWAY_HOSTNAME="${GATEWAY_HOSTNAME:-agw-demo.servebeer.com}"
export RESOURCE_BASE_URL="${RESOURCE_BASE_URL:-https://${GATEWAY_HOSTNAME}}"

# TLS cert paths (wildcard servebeer.com)
export TLS_CERT="${TLS_CERT:-/mnt/extra/mycluster/kind/tools/Certs/wildcard.servebeer.com.crt}"
export TLS_KEY="${TLS_KEY:-/mnt/extra/mycluster/kind/tools/Certs/wildcard.servebeer.com.key}"
export TLS_CA="${TLS_CA:-/mnt/extra/mycluster/kind/tools/Certs/ca.crt}"
export TLS_SECRET_NAME="${TLS_SECRET_NAME:-gateway-tls}"

# Keycloak OIDC
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-agentgateway}"
export KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.servebeer.com:8088}"

# PostgreSQL (token exchange storage)
export PG_NAMESPACE="${PG_NAMESPACE:-postgres}"
export PG_USER="${PG_USER:-myuser}"
export PG_PASSWORD="${PG_PASSWORD:-mypassword}"
export PG_DB="${PG_DB:-mydb}"
export PG_URL="${PG_URL:-postgres://${PG_USER}:${PG_PASSWORD}@postgres.${PG_NAMESPACE}.svc.cluster.local:5432/${PG_DB}}"
