#!/usr/bin/env bash
# Host mode with spire-controller-manager in static manifest mode.
#
# Covers both ways of supplying entries at once, which is the combination most
# likely to break: a manifests-dir of ClusterStaticEntry documents the caller wrote
# themselves, plus entries from the simple schema that this action renders into the
# same directory.
#
# Also checks that ${SPIFFE_TRUST_DOMAIN} inside a manifest is expanded by the
# controller-manager rather than being taken literally.

# shellcheck source=../../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib.sh"

scenario_begin

export SPIRE_DEV_MODE=host
export SPIRE_DEV_TRUST_DOMAIN=scm.test
export SPIRE_DEV_MANIFESTS_DIR="${SCENARIO_DIR}/manifests"
# Left at auto deliberately: supplying a manifests-dir must be enough to turn the
# controller-manager on.
export SPIRE_DEV_CONTROLLER_MANAGER=auto
export SPIRE_DEV_ENTRIES="
- spiffeID: api
  selectors:
    - systemd:id:spire-dev-api.service
"

spire_dev deploy

SERVER_SOCK="/run/spire/server/sockets/main/private/api.sock"
AGENT_SOCK="/run/spire/agent/sockets/main/public/api.sock"

echo
echo "== the controller-manager was enabled by the manifests-dir alone"
check "the controller-manager is running" \
  sudo systemctl is-active --quiet spire-controller-manager@main

echo
echo "== both entry sources were reconciled"
ENTRIES="$(sudo spire-server entry show -socketPath "${SERVER_SOCK}")"
check_contains "the manifest entry exists" "${ENTRIES}" "spiffe://scm.test/db"
check_contains "the rendered entry exists" "${ENTRIES}" "spiffe://scm.test/api"

echo
echo "== the trust domain placeholder was expanded, not taken literally"
if printf '%s' "${ENTRIES}" | grep -qF 'SPIFFE_TRUST_DOMAIN'; then
  echo "FAIL an entry contains a literal \${SPIFFE_TRUST_DOMAIN}" >&2
  printf '%s\n' "${ENTRIES}" | grep -F 'SPIFFE_TRUST_DOMAIN' >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   no literal \${SPIFFE_TRUST_DOMAIN} survived into any entry"
fi
check_contains "the manifest's dnsNames were applied" "${ENTRIES}" "db.internal"

echo
echo "== workloads get the identities the manifests describe"
check_equals "the manifest-defined workload is issued its ID" \
  "spiffe://scm.test/db" \
  "$(fetch_workload_svid_id spire-dev-db "${AGENT_SOCK}" test-audience)"
check_equals "the schema-defined workload is issued its ID" \
  "spiffe://scm.test/api" \
  "$(fetch_workload_svid_id spire-dev-api "${AGENT_SOCK}" test-audience)"

echo
echo "== a manifests-dir with the controller-manager off is rejected"
# A contradiction the caller should hear about up front rather than discovering
# through a missing entry.
if (
  export SPIRE_DEV_CONTROLLER_MANAGER=false
  spire_dev deploy
) >/dev/null 2>&1; then
  echo "FAIL manifests-dir with controller-manager: false was accepted" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   the contradiction is rejected"
fi

scenario_end
