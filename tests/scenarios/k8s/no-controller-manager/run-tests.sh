#!/usr/bin/env bash
# k8s mode with the controller-manager disabled.
#
# Entries are created by exec'ing the spire-server CLI in the server pod, the same
# canonical entry schema going to a different destination. Turning the
# controller-manager off in k8s also removes the chart's own ClusterSPIFFEIDs, so
# this is the configuration where nothing but the caller's entries exist, and it is
# where a wrong parentID or selector has nowhere to hide.

# shellcheck source=../../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib.sh"

scenario_begin

export SPIRE_DEV_MODE=k8s
export SPIRE_DEV_CLUSTER=kind
export SPIRE_DEV_CLUSTER_NAME=spire-dev-nocm
export SPIRE_DEV_TRUST_DOMAIN=nocm.test
export SPIRE_DEV_NAMESPACE=spire-server
export SPIRE_DEV_CONTROLLER_MANAGER=false
# The helm test depends on the OIDC provider's test-keys pod, which needs an entry
# the controller-manager would have created, so it cannot run in this mode.
export SPIRE_DEV_OIDC_DISCOVERY_PROVIDER=false
# parentID omitted so it defaults to the node alias; see the kind scenario.
export SPIRE_DEV_ENTRIES="
- spiffeID: cliapp
  selectors:
    - k8s:ns:spire-server
    - k8s:pod-label:app:cliapp
"

spire_dev deploy

NS="${SPIRE_DEV_NAMESPACE}"
SERVER_POD="$(kubectl get pods -n "${NS}" -l app.kubernetes.io/name=server \
  -o jsonpath='{.items[0].metadata.name}')"

echo
echo "== the controller-manager is not deployed"
CM_CONTAINERS="$(kubectl get statefulset -n "${NS}" -l app.kubernetes.io/name=server \
  -o jsonpath='{.items[0].spec.template.spec.containers[*].name}')"
if printf '%s' "${CM_CONTAINERS}" | grep -qF 'controller-manager'; then
  echo "FAIL the controller-manager container is present despite controller-manager: false" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   no controller-manager container (containers: ${CM_CONTAINERS})"
fi
check_equals "no ClusterSPIFFEID objects exist" "0" \
  "$(kubectl get clusterspiffeids.spire.spiffe.io -o name 2>/dev/null | grep -c . || true)"

echo
echo "== the entry was created by the CLI"
ENTRIES="$(kubectl exec -n "${NS}" "${SERVER_POD}" -c spire-server -- spire-server entry show)"
check_contains "the caller's entry exists" "${ENTRIES}" "spiffe://nocm.test/cliapp"
check_contains "the selectors were applied" "${ENTRIES}" "pod-label:app:cliapp"
check_contains "the node alias was created by the CLI too" \
  "${ENTRIES}" "spiffe://nocm.test/spire-dev-action/agents"

echo
echo "== re-running is a no-op rather than a failure"
spire_dev deploy
ENTRIES_AFTER="$(kubectl exec -n "${NS}" "${SERVER_POD}" -c spire-server -- \
  spire-server entry show)"
check_contains "the entry still exists after a second deploy" \
  "${ENTRIES_AFTER}" "spiffe://nocm.test/cliapp"
# A duplicate would mean the already-exists case is being handled by creating
# another entry rather than by recognising it.
check_equals "the entry was not duplicated" "1" \
  "$(printf '%s' "${ENTRIES_AFTER}" | grep -cF 'spiffe://nocm.test/cliapp' || true)"

echo
echo "== teardown removes the cluster"
spire_dev teardown

scenario_end
