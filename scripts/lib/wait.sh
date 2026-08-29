#!/usr/bin/env bash
# Readiness gates.
#
# Derived from the wait_for_* helpers in spire-identity-exchange's
# tests/integration/common/common.sh and helm-charts-hardened's
# examples/bottom-turtle-ha/run-tests.sh, with the fixed 30x1s budgets replaced
# by configurable timeouts and the socket paths taken as arguments rather than
# hardcoded.
#
# The distinction that matters: a live socket only proves the process started.
# wait_for_jwt is the gate that proves an entry has actually propagated and can
# be used, which is what a caller testing their application depends on.

[ -n "${_SPIRE_DEV_WAIT_SH:-}" ] && return 0
_SPIRE_DEV_WAIT_SH=1

_wait_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "${_wait_lib_dir}/common.sh"

# wait_for_healthcheck <spire-server|spire-agent> <socket-path> [timeout]
wait_for_healthcheck() {
  local app="$1"
  local socket="$2"
  local timeout="${3:-${SPIRE_DEV_TIMEOUTS_HEALTHCHECK:-60}}"
  poll "${timeout}" 1 "${app} healthcheck on ${socket}" \
    sudo "${app}" healthcheck -socketPath "${socket}"
}

# wait_for_trust_sync <server-socket> [timeout] — the server has at least one
# trust bundle. Gates anything that depends on bundle availability.
wait_for_trust_sync() {
  local socket="$1"
  local timeout="${2:-${SPIRE_DEV_TIMEOUTS_TRUST_SYNC:-60}}"
  poll "${timeout}" 1 "trust bundle to be available on ${socket}" \
    _trust_bundle_present "${socket}"
}

_trust_bundle_present() {
  local socket="$1"
  local count
  count="$(sudo spire-server bundle list -socketPath "${socket}" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${count}" -ne 0 ]
}

# wait_for_jwt <agent-socket> [audience] [timeout] — a workload can actually
# fetch a JWT-SVID over the agent's workload API. Note this attests the calling
# process, so it only succeeds if an entry matches whatever is running this
# script; use wait_for_workload_jwt for a specific unit.
wait_for_jwt() {
  local socket="$1"
  local audience="${2:-spire-dev-action}"
  local timeout="${3:-${SPIRE_DEV_TIMEOUTS_JWT:-60}}"
  poll "${timeout}" 1 "a JWT-SVID to be issuable on ${socket}" \
    sudo spire-agent api fetch jwt -audience "${audience}" -socketPath "${socket}"
}

# wait_for_entry <server-socket> <spiffe-id> [timeout] — a registration entry
# for the given SPIFFE ID exists. Used after handing manifests to the
# controller-manager, which creates entries asynchronously.
wait_for_entry() {
  local socket="$1"
  local spiffe_id="$2"
  local timeout="${3:-${SPIRE_DEV_TIMEOUTS_ENTRY:-90}}"
  poll "${timeout}" 2 "registration entry ${spiffe_id}" \
    _entry_present "${socket}" "${spiffe_id}"
}

_entry_present() {
  local socket="$1"
  local spiffe_id="$2"
  sudo spire-server entry show -socketPath "${socket}" -spiffeID "${spiffe_id}" 2>/dev/null |
    grep -q "SPIFFE ID"
}

# wait_for_entry_count <server-socket> [timeout] — at least one entry exists,
# without caring which. Cheaper gate for "the controller-manager is working".
wait_for_entry_count() {
  local socket="$1"
  local timeout="${2:-${SPIRE_DEV_TIMEOUTS_ENTRY:-90}}"
  poll "${timeout}" 2 "at least one registration entry" \
    _entry_count_nonzero "${socket}"
}

_entry_count_nonzero() {
  local socket="$1"
  local out
  out="$(sudo spire-server entry show -socketPath "${socket}" 2>/dev/null)" || return 1
  [ "${out}" != "Found 0 entries" ]
}

# wait_for_file <path> [timeout]
wait_for_file() {
  local path="$1"
  local timeout="${2:-60}"
  poll "${timeout}" 1 "file ${path} to exist" test -f "${path}"
}

# wait_for_url <url> [timeout] [curl-arg...] — poll an HTTP(S) endpoint for a
# successful response.
wait_for_url() {
  local url="$1"
  local timeout="${2:-60}"
  shift 2
  poll "${timeout}" 2 "${url} to respond" \
    curl -sS -o /dev/null --fail "$@" "${url}"
}

# wait_for_listener <url> [timeout] [curl-arg...] — poll until something answers,
# whatever the status code.
#
# For a service whose root path is not a real endpoint: an HTTP 404 still proves
# the listener is up, which is all this is checking.
wait_for_listener() {
  local url="$1"
  local timeout="${2:-60}"
  shift 2
  poll "${timeout}" 2 "${url} to accept connections" \
    curl -sS -o /dev/null "$@" "${url}"
}

# wait_for_systemd_unit <unit> [timeout] — the unit reached active state. Gives
# a clearer failure than waiting on the socket a broken unit never creates.
wait_for_systemd_unit() {
  local unit="$1"
  local timeout="${2:-60}"
  poll "${timeout}" 1 "systemd unit ${unit} to become active" \
    sudo systemctl is-active --quiet "${unit}"
}

# dump_unit_failure <unit> — print why a unit is not running.
#
# Called on any start or healthcheck failure. Without this a timeout reports only
# that something did not become healthy, which is never enough to act on and sends
# the reader off to find an artifact; the journal almost always names the cause on
# the first try.
dump_unit_failure() {
  local unit="$1"
  log_error "${unit} did not come up; its status and log follow"
  log_group "${unit} status"
  sudo systemctl status --no-pager --full "${unit}" 2>&1 | sed 's/^/  /' || true
  log_endgroup
  log_group "${unit} log"
  sudo journalctl --no-pager -u "${unit}" -n 100 2>&1 | sed 's/^/  /' || true
  log_endgroup
}

# wait_for_workload_jwt <unit-name> <agent-socket> [audience] [timeout]
#
# Fetches a JWT-SVID as a transient systemd unit, so the agent's systemd
# workload attestor sees selector systemd:id:<unit>.service. This is how a raw
# unix workload gets a scoped SVID without a container, and it is the mechanism
# the self-tests and the README use to prove an entry works.
wait_for_workload_jwt() {
  local unit="$1"
  local socket="$2"
  local audience="${3:-spire-dev-action}"
  local timeout="${4:-${SPIRE_DEV_TIMEOUTS_JWT:-60}}"
  poll "${timeout}" 2 "unit ${unit} to be issued a JWT-SVID" \
    _workload_jwt "${unit}" "${socket}" "${audience}"
}

_workload_jwt() {
  local unit="$1"
  local socket="$2"
  local audience="$3"
  # A failed transient unit stays registered and blocks reuse of the name.
  sudo systemctl reset-failed "${unit}.service" 2>/dev/null || true
  sudo timeout 15 systemd-run --wait --pipe --unit="${unit}" \
    spire-agent api fetch jwt -audience "${audience}" -socketPath "${socket}"
}

# fetch_workload_svid_id <unit-name> <agent-socket> [audience]
#
# Echoes the SPIFFE ID from a JWT-SVID fetched as the given systemd unit, for
# asserting that a workload got the identity the caller asked for.
fetch_workload_svid_id() {
  local unit="$1"
  local socket="$2"
  local audience="${3:-spire-dev-action}"
  require_cmd jq
  sudo systemctl reset-failed "${unit}.service" 2>/dev/null || true
  sudo timeout 15 systemd-run --wait --pipe --unit="${unit}" \
    spire-agent api fetch jwt -audience "${audience}" -socketPath "${socket}" -output json |
    jq -r '.[0].svids[0].spiffe_id // empty'
}

# --- Kubernetes gates -------------------------------------------------------

# wait_for_rollout <namespace> <resource> [timeout-seconds] — rollout status
# with the pod logs dumped on failure, so a stuck rollout explains itself
# instead of just timing out.
wait_for_rollout() {
  local namespace="$1"
  local resource="$2"
  local timeout="${3:-${SPIRE_DEV_TIMEOUTS_ROLLOUT:-180}}"
  if ! kubectl rollout status "${resource}" -n "${namespace}" --timeout "${timeout}s"; then
    log_error "rollout of ${resource} in ${namespace} did not complete"
    kubectl logs "${resource}" -n "${namespace}" --prefix --all-containers=true --tail=100 || true
    kubectl describe "${resource}" -n "${namespace}" || true
    return 1
  fi
}

# wait_for_k8s_entry_count <namespace> <server-pod> [timeout] — at least one
# registration entry, queried inside the server pod.
wait_for_k8s_entry_count() {
  local namespace="$1"
  local pod="$2"
  local timeout="${3:-${SPIRE_DEV_TIMEOUTS_ENTRY:-90}}"
  poll "${timeout}" 3 "at least one registration entry in ${namespace}/${pod}" \
    _k8s_entry_count_nonzero "${namespace}" "${pod}"
}

_k8s_entry_count_nonzero() {
  local namespace="$1"
  local pod="$2"
  local out
  out="$(kubectl exec -n "${namespace}" "${pod}" -c spire-server -- \
    spire-server entry show 2>/dev/null)" || return 1
  [ "${out}" != "Found 0 entries" ]
}
