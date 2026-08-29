#!/usr/bin/env bash
# Host mode with the controller-manager disabled: entries are created with the
# spire-server CLI, which is the path that makes the controller-manager optional.
#
# Also covers the OIDC discovery provider, since host mode has to supply its own
# unit and config for it.
#
# The real assertion is not that SPIRE started but that a workload gets the
# identity that was asked for. Proving that for a raw unix process means running it
# as a transient systemd unit, so the agent's systemd workload attestor produces a
# selector to match on. That is the same mechanism the README recommends to callers.

# shellcheck source=../../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib.sh"

scenario_begin

export SPIRE_DEV_MODE=host
export SPIRE_DEV_TRUST_DOMAIN=cli-entries.test
export SPIRE_DEV_CONTROLLER_MANAGER=false
export SPIRE_DEV_OIDC_DISCOVERY_PROVIDER=true
export SPIRE_DEV_ENTRIES="
- spiffeID: myapp
  selectors:
    - systemd:id:spire-dev-myapp.service
- spiffeID: /other/worker
  selectors:
    - systemd:id:spire-dev-worker.service
  dnsNames:
    - worker.cli-entries.test
"

spire_dev deploy

AGENT_SOCK="/run/spire/agent/sockets/main/public/api.sock"
SERVER_SOCK="/run/spire/server/sockets/main/private/api.sock"

echo
echo "== the deployment is up"
# sudo for the server socket: SPIRE creates the private API socket's directory
# mode 0750 owned by root, so an unprivileged stat cannot traverse into it. The
# agent's public socket is reachable by anyone, which is the point of it.
check "the server socket exists" sudo test -S "${SERVER_SOCK}"
check "the agent socket exists" test -S "${AGENT_SOCK}"
check "the server is healthy" sudo spire-server healthcheck -socketPath "${SERVER_SOCK}"
check "the agent is healthy" sudo spire-agent healthcheck -socketPath "${AGENT_SOCK}"

echo
echo "== the controller-manager was not started"
# Requested false, so it must not be running even though it may be installed.
if sudo systemctl is-active --quiet spire-controller-manager@main; then
  echo "FAIL the controller-manager is running despite controller-manager: false" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   the controller-manager is not running"
fi

echo
echo "== the entries exist with the right SPIFFE IDs"
ENTRIES="$(sudo spire-server entry show -socketPath "${SERVER_SOCK}")"
check_contains "myapp was created" "${ENTRIES}" "spiffe://cli-entries.test/myapp"
check_contains "the worker was created" "${ENTRIES}" "spiffe://cli-entries.test/other/worker"
check_contains "the parent defaulted to the agent" "${ENTRIES}" "spiffe://cli-entries.test/agent/node1"
check_contains "the dnsNames field was applied" "${ENTRIES}" "worker.cli-entries.test"

echo
echo "== a workload actually gets the identity it was promised"
# The unit name has to match the systemd:id selector on the myapp entry.
ACTUAL_ID="$(fetch_workload_svid_id spire-dev-myapp "${AGENT_SOCK}" test-audience)"
check_equals "myapp is issued its own SPIFFE ID" \
  "spiffe://cli-entries.test/myapp" "${ACTUAL_ID}"

# An X509-SVID over the same path, since most applications use that rather than a
# JWT-SVID.
sudo systemctl reset-failed spire-dev-myapp.service 2>/dev/null || true
X509_OUT="$(sudo timeout 20 systemd-run --wait --pipe --unit=spire-dev-myapp \
  spire-agent api fetch x509 -socketPath "${AGENT_SOCK}" 2>&1 || true)"
check_contains "myapp is issued an X509-SVID" "${X509_OUT}" "spiffe://cli-entries.test/myapp"

echo
echo "== a workload with no matching entry gets nothing"
# Guards against an entry that is too broad: a selector that matched anything would
# make every check above pass for the wrong reason.
sudo systemctl reset-failed spire-dev-unregistered.service 2>/dev/null || true
if sudo timeout 20 systemd-run --wait --pipe --unit=spire-dev-unregistered \
  spire-agent api fetch jwt -audience test-audience -socketPath "${AGENT_SOCK}" >/dev/null 2>&1; then
  echo "FAIL an unregistered workload was issued an SVID" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   an unregistered workload is refused"
fi

echo
echo "== the OIDC discovery provider serves its document"
DISCOVERY="$(curl -sS --fail "http://127.0.0.1:8181/.well-known/openid-configuration")"
check_contains "the discovery document names the issuer" "${DISCOVERY}" "issuer"
check "the JWKS endpoint responds" curl -sS --fail "http://127.0.0.1:8181/keys"

echo
echo "== the trust bundle was written"
check "the bundle file exists" test -s "${SPIRE_DEV_WORK_DIR}/bundle.pem"
check_contains "the bundle is a certificate" \
  "$(cat "${SPIRE_DEV_WORK_DIR}/bundle.pem")" "BEGIN CERTIFICATE"

echo
echo "== re-running is a no-op rather than a failure"
# A caller may reasonably invoke the action twice, and an already-existing entry
# must not fail the job.
spire_dev deploy
check "the entries still exist after a second deploy" \
  sudo spire-server entry show -socketPath "${SERVER_SOCK}" -spiffeID "spiffe://cli-entries.test/myapp"

scenario_end
