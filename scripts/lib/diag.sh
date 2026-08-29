#!/usr/bin/env bash
# Diagnostics collection.
#
# Invoked by diagnostics/action.yml with `if: always()`. Nothing here may fail the
# job: it runs when something has already gone wrong, and its own failure would
# replace the real error with a less useful one. Hence `|| true` throughout.
#
# Output goes to two places: the run summary, for someone reading the failed job,
# and a directory of files, for the diagnostics action to upload as an artifact.

[ -n "${_SPIRE_DEV_DIAG_SH:-}" ] && return 0
_SPIRE_DEV_DIAG_SH=1

_diag_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "${_diag_lib_dir}/common.sh"

# diag_dir — where collected files are written.
diag_dir() {
  work_dir diagnostics
}

# _diag_capture <name> <command...> — run a command, tee its output to a file in
# the diagnostics directory and to a collapsed log group.
_diag_capture() {
  local name="$1"
  shift
  local out
  out="$(diag_dir)/${name}.txt"

  log_group "${name}"
  {
    echo "\$ $*"
    "$@" 2>&1 || echo "(command failed with status $?)"
  } | tee "${out}" || true
  log_endgroup
}

diag_collect() {
  mkdir -p "$(diag_dir)"
  log_info "collecting diagnostics into $(diag_dir)"

  case "${SPIRE_DEV_MODE:-}" in
  host) _diag_host ;;
  k8s) _diag_k8s ;;
  *) log_warn "mode is not set; collecting nothing" ;;
  esac

  log_set_output diagnostics-dir "$(diag_dir)"
  log_summary_truncate
}

_diag_host() {
  # shellcheck source=../host/paths.sh
  . "${_diag_lib_dir}/../host/paths.sh"

  local instance="${SPIRE_DEV_INSTANCE}"
  local unit

  while read -r unit; do
    [ -z "${unit}" ] && continue
    # A unit that was never started is normal (the optional components), so only
    # report on the ones systemd knows about.
    if sudo systemctl list-units --all --plain --no-legend "${unit}.service" 2>/dev/null |
      grep -q .; then
      _diag_capture "systemctl-status-${unit}" \
        sudo systemctl status --no-pager --full "${unit}"
      _diag_capture "journal-${unit}" \
        sudo journalctl --no-pager -u "${unit}" -n 200
    fi
  done < <(host_units)

  local server_sock
  server_sock="$(server_socket "${instance}")"
  if [ -S "${server_sock}" ]; then
    _diag_capture "entry-show" \
      sudo spire-server entry show -socketPath "${server_sock}"
    _diag_capture "bundle-list" \
      sudo spire-server bundle list -socketPath "${server_sock}"
    _diag_capture "agent-list" \
      sudo spire-server agent list -socketPath "${server_sock}"
  else
    log_warn "the server socket ${server_sock} does not exist; the server never started"
  fi

  _diag_capture "static-manifests" \
    sudo find "$(static_manifest_dir "${instance}")" -type f -exec cat {} +

  # The generated env files are the most common source of a misconfiguration, and
  # the join token in the agent file is masked in the CI log rather than printed.
  local env_file
  for env_file in "$(trust_domain_env)" "$(server_env "${instance}")" \
    "$(controller_manager_env "${instance}")"; do
    [ -f "${env_file}" ] && _diag_capture "env-$(basename "${env_file}")" sudo cat "${env_file}"
  done
  if [ -f "$(agent_env "${instance}")" ]; then
    _diag_capture "env-agent" \
      sudo grep -v '^JOIN_TOKEN=' "$(agent_env "${instance}")"
  fi

  _diag_capture "installed-packages" \
    dpkg-query -W -f='${Package} ${Version}\n' 'spire*' 'spiffe*'

  _diag_summary_host
}

_diag_summary_host() {
  log_summary ""
  log_summary "### SPIRE unit status (host mode)"
  log_summary ""
  log_summary "| Unit | State |"
  log_summary "|---|---|"
  local unit state
  while read -r unit; do
    [ -z "${unit}" ] && continue
    state="$(sudo systemctl is-active "${unit}" 2>/dev/null || echo "not started")"
    log_summary "| \`${unit}\` | ${state} |"
  done < <(host_units)
}

_diag_k8s() {
  local namespace="${SPIRE_DEV_NAMESPACE}"

  command -v kubectl >/dev/null 2>&1 || {
    log_warn "kubectl is not available; collecting nothing"
    return 0
  }

  _diag_capture "helm-releases" helm ls -A
  _diag_capture "get-all" kubectl get all -n "${namespace}" -o wide
  _diag_capture "events" \
    kubectl get events -n "${namespace}" --sort-by=.lastTimestamp -o wide
  _diag_capture "describe-pods" kubectl describe pods -n "${namespace}"
  _diag_capture "crs" \
    kubectl get clusterspiffeids.spire.spiffe.io,clusterstaticentries.spire.spiffe.io \
    -o yaml

  # Per-pod logs, including previous containers: a crash-looping pod's useful
  # output is in the previous instance, not the current one.
  local pod
  while read -r pod; do
    [ -z "${pod}" ] && continue
    _diag_capture "logs-${pod}" \
      kubectl logs -n "${namespace}" "${pod}" --prefix --all-containers=true \
      --tail=200 --ignore-errors=true
    _diag_capture "logs-previous-${pod}" \
      kubectl logs -n "${namespace}" "${pod}" --prefix --all-containers=true \
      --tail=200 --ignore-errors=true --previous
  done < <(kubectl get pods -n "${namespace}" -o name 2>/dev/null | sed 's|pod/||')

  local server_pod
  server_pod="$(kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=server" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${server_pod}" ]; then
    _diag_capture "entry-show" kubectl exec -n "${namespace}" "${server_pod}" \
      -c spire-server -- spire-server entry show
    _diag_capture "bundle-list" kubectl exec -n "${namespace}" "${server_pod}" \
      -c spire-server -- spire-server bundle list
    _diag_capture "agent-list" kubectl exec -n "${namespace}" "${server_pod}" \
      -c spire-server -- spire-server agent list
  fi

  _diag_summary_k8s "${namespace}"
}

_diag_summary_k8s() {
  local namespace="$1"
  log_summary ""
  log_summary "### SPIRE workload status (k8s mode)"
  log_summary ""
  log_summary '```'
  kubectl get pods -n "${namespace}" -o wide 2>&1 |
    while IFS= read -r line; do log_summary "${line}"; done
  log_summary '```'
}
