#!/usr/bin/env bash
# Host mode with spire-identity-exchange.
#
# The most involved host scenario, and the one whose wiring cannot be checked
# offline: it depends on spire-credentialcomposer-identity-exchange resolving from
# the spire-examples feed, on that composer setting the CN that the x509pop node
# alias selector matches, and on the second agent attesting through x509pop in
# SPIFFE mode. Every one of those either works end to end or the exchange never
# serves, so this scenario is the check.
#
# The exchange is deployed with every auth plugin disabled, which is the default.
# That is still a meaningful test: it exercises all the bootstrap machinery, and
# what a caller would additionally configure is only policy about whose credentials
# to accept.

# shellcheck source=../../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib.sh"

scenario_begin

export SPIRE_DEV_MODE=host
export SPIRE_DEV_TRUST_DOMAIN=six.test
export SPIRE_DEV_IDENTITY_EXCHANGE=true
export SPIRE_DEV_ENTRIES="
- spiffeID: myapp
  selectors:
    - systemd:id:spire-dev-myapp.service
"

spire_dev deploy

SERVER_SOCK="/run/spire/server/sockets/main/private/api.sock"
AGENT_SOCK="/run/spire/agent/sockets/main/public/api.sock"
SIX_AGENT_SOCK="/run/spire/agent/sockets/main-six/public/api.sock"
CERT="/etc/spire/identity-exchange/main/certs/server.pem"

echo
echo "== the second agent bootstraps the same way the primary one does"
# The rebootstrap path this deliberately does not use needs a package, a unit and
# an entry that nothing else here provides; if it ever comes back by accident the
# agent hangs waiting on a socket that never appears, which is a slow and confusing
# failure. Cheaper to assert the config.
SIX_AGENT_CONF="/etc/spire/agent/main-six.conf"
check "the second agent's config exists" sudo test -f "${SIX_AGENT_CONF}"
# Anchored to the start of a line, because the config's own comments explain the
# rebootstrap settings it deliberately does not use, and an unanchored match reads
# that prose as configuration.
if sudo grep -qE '^[[:space:]]*(trust_bundle_url|trust_bundle_unix_socket|rebootstrap_mode|rebootstrap_delay)' "${SIX_AGENT_CONF}"; then
  echo "FAIL the second agent is configured to rebootstrap, which needs a server attestor this action does not deploy" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   the second agent does not depend on a rebootstrap trust-bundle source"
fi

echo
echo "== both agent instances are healthy"
check "the primary agent is healthy" \
  sudo spire-agent healthcheck -socketPath "${AGENT_SOCK}"
check "the exchange's agent instance is healthy" \
  sudo spire-agent healthcheck -socketPath "${SIX_AGENT_SOCK}"

echo
echo "== the second agent attested, which proves the x509pop chain works"
# The load-bearing assertion. The second agent can only appear here if the credential
# composer set the CN on the SVID it holds, the node alias matched that CN, and the
# server's x509pop attestor in SPIFFE mode accepted it.
#
# Two different SPIFFE IDs are involved and they are easy to confuse. The SVID the
# agent presents is spiffe://<td>/spire-exchange/spire-identity-exchange/<node>, from
# the entry that lets it obtain one. The ID asserted here is the one the server
# assigns after attestation, built from the plugin's agent_path_template
# (/{{ .PluginName }}/spire-identity-exchange/{{ .SVIDPathTrimmed }}) under
# spiffe://<td>/spire/agent.
AGENTS="$(sudo spire-server agent list -socketPath "${SERVER_SOCK}")"
check_contains "the exchange's agent is attested under the templated agent ID" \
  "${AGENTS}" "spiffe://six.test/spire/agent/x509pop/spire-identity-exchange/node1"
# Names the mechanism, not just the outcome: a join_token agent appearing at this ID
# would mean the x509pop path was silently bypassed.
check_contains "it attested via x509pop" "${AGENTS}" "Attestation type  : x509pop"
check_contains "the primary agent is still attested via its join token" \
  "${AGENTS}" "Attestation type  : join_token"

echo
echo "== the bootstrap entries exist"
ENTRIES="$(sudo spire-server entry show -socketPath "${SERVER_SOCK}")"
check_contains "the node alias exists" "${ENTRIES}" "spiffe://six.test/spire-identity-exchange"
check_contains "the exchange's service entry exists" "${ENTRIES}" \
  "spiffe://six.test/service/spire-identity-exchange"
check_contains "the caller's own entry is untouched" "${ENTRIES}" "spiffe://six.test/myapp"

echo
echo "== the exchange is serving on both listeners"
check "the REST listener answers" \
  curl -sS -o /dev/null --insecure "https://localhost:8444"
check "the gRPC listener accepts connections" \
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/8443'

echo
echo "== the served certificate matches the generated one"
check "the certificate exists" sudo test -f "${CERT}"
SERVED="$(echo | openssl s_client -connect 127.0.0.1:8444 2>/dev/null |
  openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
EXPECTED="$(sudo openssl x509 -in "${CERT}" -noout -fingerprint -sha256 2>/dev/null || true)"
check_equals "the exchange serves the certificate this action generated" \
  "${EXPECTED}" "${SERVED}"

echo
echo "== the delegated identity API is available to the exchange"
# What the exchange actually consumes: the second agent's admin socket, which is the
# capability it needs to mint SVIDs for the callers it authenticates. The TLS
# listeners above prove nothing about this, since they serve a certificate from disk.
check "the delegated admin socket exists" \
  sudo test -S "/var/run/spire/agent/sockets/main-six/private/admin.sock"
check_equals "the exchange's service entry resolves to one SPIFFE ID" \
  "spiffe://six.test/service/spire-identity-exchange" \
  "$(sudo spire-server entry show -socketPath "${SERVER_SOCK}" \
    -spiffeID spiffe://six.test/service/spire-identity-exchange 2>/dev/null |
    sed -n 's/^SPIFFE ID *: *//p' | head -1)"

echo
echo "== the caller's application still works alongside the exchange"
# The second agent and the delegated socket must not disturb the primary workload
# API, which is what the caller's application uses.
check_equals "myapp is still issued its SPIFFE ID" \
  "spiffe://six.test/myapp" \
  "$(fetch_workload_svid_id spire-dev-myapp "${AGENT_SOCK}" test-audience)"

scenario_end
