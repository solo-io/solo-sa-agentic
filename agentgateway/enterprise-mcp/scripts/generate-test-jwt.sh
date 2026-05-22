#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JWT_PRIVATE_KEY="${JWT_PRIVATE_KEY:-${SCRIPT_DIR}/fixtures/test-agent-private-key.pem}"
ISSUER="${ISSUER:-http://enterprise-idp.agentgateway-system.svc.cluster.local:8080/realms/agents}"
AUDIENCE="${AUDIENCE:-enterprise-mcp-platform}"
AGENT_ID="${1:-}"
SCOPE="${2:-}"
SUBJECT="${SUBJECT:-manual-curl}"
TTL_SECONDS="${TTL_SECONDS:-900}"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
usage: scripts/generate-test-jwt.sh <agent-id> <scope>

examples:
  scripts/generate-test-jwt.sh agt-account-servicing-prod accounts.read
  scripts/generate-test-jwt.sh agt-case-management-prod cases.write
  scripts/generate-test-jwt.sh agt-supervisor-prod agents.delegate
EOF
}

base64url_file() {
  openssl base64 -A -in "$1" | tr '+/' '-_' | tr -d '='
}

if [[ -z "$AGENT_ID" || -z "$SCOPE" ]]; then
  usage
  exit 2
fi

command -v openssl >/dev/null 2>&1 || {
  printf 'error: missing required command: openssl\n' >&2
  exit 1
}

[[ -f "$JWT_PRIVATE_KEY" ]] || {
  printf 'error: JWT private key not found: %s\n' "$JWT_PRIVATE_KEY" >&2
  exit 1
}

now="$(date +%s)"
exp="$((now + TTL_SECONDS))"
header_file="${TMP_DIR}/header.json"
payload_file="${TMP_DIR}/payload.json"
signing_input_file="${TMP_DIR}/signing-input.txt"
signature_file="${TMP_DIR}/signature.bin"

cat >"$header_file" <<'JSON'
{"alg":"RS256","typ":"JWT","kid":"enterprise-mcp-test-key"}
JSON

cat >"$payload_file" <<JSON
{"iss":"${ISSUER}","aud":"${AUDIENCE}","sub":"${SUBJECT}","agent_id":"${AGENT_ID}","scope":["${SCOPE}"],"iat":${now},"exp":${exp}}
JSON

header="$(base64url_file "$header_file")"
payload="$(base64url_file "$payload_file")"
printf '%s.%s' "$header" "$payload" >"$signing_input_file"
openssl dgst -sha256 -sign "$JWT_PRIVATE_KEY" -out "$signature_file" "$signing_input_file"
signature="$(base64url_file "$signature_file")"

printf '%s.%s.%s\n' "$header" "$payload" "$signature"
