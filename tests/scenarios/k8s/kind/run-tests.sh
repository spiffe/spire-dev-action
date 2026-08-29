#!/usr/bin/env bash
# k8s mode with a kind cluster created by the action, in the default configuration.
#
# The two things worth proving beyond "helm succeeded":
#   * k8s_psat node attestation works without the legacy apiserver patches this
#     action chose not to carry. If it ever does not, this is where it surfaces, and
#     the k8s version matrix is what makes that meaningful.
#   * a pod mounting the CSI driver actually receives an SVID, which is what a
#     caller's application depends on.

# shellcheck source=../../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib.sh"

scenario_begin

export SPIRE_DEV_MODE=k8s
export SPIRE_DEV_CLUSTER=kind
export SPIRE_DEV_CLUSTER_NAME=spire-dev-test
export SPIRE_DEV_TRUST_DOMAIN=kind.test
export SPIRE_DEV_NAMESPACE=spire-server
# No parentID: it defaults to the node alias the action creates, which is what a
# workload entry has to parent on. Naming the server here instead would create
# something SPIRE treats as a node alias, and no workload would ever match it.
export SPIRE_DEV_ENTRIES="
- spiffeID: myapp
  selectors:
    - k8s:ns:${SPIRE_DEV_NAMESPACE}
    - k8s:pod-label:app:spire-dev-workload
"

# The cluster outlives the scenario only if it succeeds; leaving it behind on
# failure would waste the runner's remaining time.
cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    log_warn "scenario failed; leaving the cluster up for the diagnostics step"
  fi
  return "${rc}"
}
trap cleanup EXIT

spire_dev deploy

NS="${SPIRE_DEV_NAMESPACE}"

echo
echo "== the workloads are running"
check "the server statefulset is ready" \
  kubectl rollout status statefulset -n "${NS}" -l app.kubernetes.io/name=server --timeout=60s
check "the agent daemonset is ready" \
  kubectl rollout status daemonset -n "${NS}" -l app.kubernetes.io/name=agent --timeout=60s
check "the CSI driver is registered" kubectl get csidriver csi.spiffe.io

echo
echo "== the agent attested to the server"
SERVER_POD="$(kubectl get pods -n "${NS}" -l app.kubernetes.io/name=server \
  -o jsonpath='{.items[0].metadata.name}')"
AGENTS="$(kubectl exec -n "${NS}" "${SERVER_POD}" -c spire-server -- spire-server agent list)"
# This is the k8s_psat check: no attested agent means node attestation failed.
check_contains "an agent is attested via k8s_psat" "${AGENTS}" "spiffe://kind.test/spire/agent/k8s_psat"

echo
echo "== the entries exist"
ENTRIES="$(kubectl exec -n "${NS}" "${SERVER_POD}" -c spire-server -- spire-server entry show)"
check_contains "the caller's entry exists" "${ENTRIES}" "spiffe://kind.test/myapp"
check_contains "the node alias the entry parents on exists" \
  "${ENTRIES}" "spiffe://kind.test/spire-dev-action/agents"
if printf '%s' "${ENTRIES}" | grep -qF 'Found 0 entries'; then
  echo "FAIL no entries exist" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
fi

echo
echo "== a pod mounting the CSI driver receives an SVID"
# The agent image comes from the chart so it cannot drift from the deployment, and
# it already contains the spire-agent CLI the pod uses to fetch an SVID.
AGENT_IMAGE="$(kubectl get daemonset -n "${NS}" -l app.kubernetes.io/name=agent \
  -o jsonpath='{.items[0].spec.template.spec.containers[?(@.name=="spire-agent")].image}')"
log_info "workload image: ${AGENT_IMAGE}"

yq "(.spec.containers[] | select(.name == \"main\") | .image) = \"${AGENT_IMAGE}\"" \
  "${SCENARIO_DIR}/workload.yaml" | kubectl apply -n "${NS}" -f -

# Waits for Succeeded, not Ready: the pod fetches an SVID and exits, so it never
# becomes Ready and waiting on that would just burn the timeout before failing.
if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/spire-dev-workload \
  -n "${NS}" --timeout=120s; then
  WORKLOAD_OUT="$(kubectl logs -n "${NS}" pod/spire-dev-workload 2>&1 || true)"
  check_contains "the pod was issued the expected SPIFFE ID" \
    "${WORKLOAD_OUT}" "spiffe://kind.test/myapp"
else
  echo "FAIL the workload pod did not complete successfully" >&2
  kubectl describe pod spire-dev-workload -n "${NS}" >&2 || true
  kubectl logs -n "${NS}" pod/spire-dev-workload >&2 2>&1 || true
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
fi
kubectl delete pod spire-dev-workload -n "${NS}" --ignore-not-found --wait=false || true

echo
echo "== the trust domain was applied everywhere"
# Fetched by name, not by label: the chart's configmaps carry no labels at all, so
# a label selector matches nothing and silently yields an empty list.
SERVER_CONFIG="$(kubectl get configmap "${SPIRE_DEV_RELEASE_NAME:-spire}-server" \
  -n "${NS}" -o yaml 2>/dev/null || true)"
check_contains "the server config uses the requested trust domain" \
  "${SERVER_CONFIG}" "kind.test"
check_absent "no leftover example.org in the server config" \
  "${SERVER_CONFIG}" "example.org"

echo
echo "== teardown removes the cluster"
spire_dev teardown
if kind get clusters 2>/dev/null | grep -qx "${SPIRE_DEV_CLUSTER_NAME}"; then
  echo "FAIL the kind cluster still exists after teardown" >&2
  SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
else
  echo "ok   the kind cluster was deleted"
fi

scenario_end
