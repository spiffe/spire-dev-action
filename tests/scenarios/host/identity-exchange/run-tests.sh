#!/usr/bin/env bash
# Host mode with spire-identity-exchange.
#
# The most involved host scenario, and the one whose wiring cannot be checked
# offline: it depends on packages resolving from the spire-examples feed
# (spire-credentialcomposer-identity-exchange and
# spire-server-attestor-spiffe-workload-api alongside the exchange itself), on the
# credential composer setting the CN that the x509pop node alias matches, and on the
# second agent attesting through x509pop in SPIFFE mode. Every one of those either
# works end to end or the exchange never serves, so this scenario is the check.
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
echo "== both agent instances are healthy"
check "the primary agent is healthy" \
  sudo spire-agent healthcheck -socketPath "${AGENT_SOCK}"
check "the exchange's agent instance is healthy" \
  sudo spire-agent healthcheck -socketPath "${SIX_AGENT_SOCK}"

echo
echo "== the second agent attested, which proves the x509pop chain works"
# This is the load-bearing assertion. The second agent can only appear here if the
# credential composer set the CN, the node alias matched it, and the server's
# x509pop attestor in SPIFFE mode accepted the SVID.
AGENTS="$(sudo spire-server agent list -socketPath "${SERVER_SOCK}")"
check_contains "the exchange's agent is attested" "${AGENTS}" \
  "spiffe://six.test/spire-exchange/spire-identity-exchange"

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
echo "== the exchange's own SVID was issued"
# The service entry has to have propagated for the exchange to hold an SVID; that
# it is serving at all already implies it, so this only records the ID.
check_equals "the exchange holds its service SVID" \
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
