#!/usr/bin/env bash
# Host mode: deploy SPIRE from the spire-examples debs onto this machine.
#
# Ordering is load-bearing:
#   1. server config and start, so the server socket exists
#   2. join token, which needs a running server
#   3. agent start, which needs the token in its EnvironmentFile
#   4. entries, which need a running server (and the controller-manager, if used)
# Steps 2 and 3 cannot be reordered: the agent's attested identity comes from the
# SPIFFE ID the token was issued for.

[ -n "${_SPIRE_DEV_HOST_DEPLOY_SH:-}" ] && return 0
_SPIRE_DEV_HOST_DEPLOY_SH=1

_host_deploy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./install.sh
. "${_host_deploy_dir}/install.sh"
# shellcheck source=./configure.sh
. "${_host_deploy_dir}/configure.sh"
# shellcheck source=./oidc.sh
. "${_host_deploy_dir}/oidc.sh"
# shellcheck source=../lib/wait.sh
. "${_host_deploy_dir}/../lib/wait.sh"
# shellcheck source=../lib/entries.sh
. "${_host_deploy_dir}/../lib/entries.sh"

host_deploy() {
  local instance="${SPIRE_DEV_INSTANCE}"
  local trust_domain="${SPIRE_DEV_TRUST_DOMAIN}"
  local agent_id="spiffe://${trust_domain}/agent/${SPIRE_DEV_NODE_ID}"

  host_assert_supported
  host_assert_allowed

  host_resolve_controller_manager
  host_install_packages

  # Before host_configure, not inside host_deploy_six at the end: enabling the
  # exchange makes host_configure add a CredentialComposer to the server config
  # that names a plugin binary on disk. If that binary is missing the server dies
  # at startup with nothing pointing at the cause, so the check has to precede the
  # config that depends on it.
  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE}"; then
    # shellcheck source=./six.sh
    . "${_host_deploy_dir}/six.sh"
    six_assert_installed
  fi

  host_configure

  # --- server -------------------------------------------------------------
  log_group "Starting SPIRE server"
  local server_sock
  server_sock="$(server_socket "${instance}")"
  sudo systemctl daemon-reload
  sudo systemctl restart "$(server_unit "${instance}")" ||
    log_fail "could not start $(server_unit "${instance}")"
  if ! wait_for_healthcheck spire-server "${server_sock}"; then
    dump_unit_failure "$(server_unit "${instance}")"
    log_fail "the SPIRE server did not become healthy"
  fi
  log_endgroup

  # --- agent --------------------------------------------------------------
  log_group "Starting SPIRE agent"
  host_write_join_token "${instance}" "${agent_id}"
  local agent_sock
  agent_sock="$(agent_socket "${instance}")"
  sudo systemctl restart "$(agent_unit "${instance}")" ||
    log_fail "could not start $(agent_unit "${instance}")"
  if ! wait_for_healthcheck spire-agent "${agent_sock}"; then
    dump_unit_failure "$(agent_unit "${instance}")"
    log_fail "the SPIRE agent did not become healthy"
  fi
  log_endgroup

  # --- entries ------------------------------------------------------------
  host_apply_entries "${instance}" "${agent_id}"

  # --- optional components ------------------------------------------------
  if is_true "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER}"; then
    host_deploy_oidc "${instance}"
  fi
  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE}"; then
    host_deploy_six "${instance}" "${agent_id}"
  fi

  host_publish_outputs "${instance}" "${agent_id}"
}

# host_resolve_controller_manager — settle the auto default.
#
# The controller-manager is optional on a host: without it, entries are created
# with the spire-server CLI. It is turned on automatically when the caller
# supplied a manifests directory, because that input has no other consumer.
host_resolve_controller_manager() {
  local requested="${SPIRE_DEV_CONTROLLER_MANAGER:-auto}"
  local resolved

  case "$(printf '%s' "${requested}" | tr '[:upper:]' '[:lower:]')" in
  auto)
    if [ -n "${SPIRE_DEV_MANIFESTS_DIR}" ]; then
      resolved=true
      log_info "controller-manager: enabled (a manifests-dir was supplied)"
    else
      resolved=false
      log_info "controller-manager: disabled (entries will be created with the spire-server CLI)"
    fi
    ;;
  *)
    if is_true "${requested}"; then
      resolved=true
    elif is_false "${requested}"; then
      resolved=false
    else
      log_fail "controller-manager must be true, false or auto; got '${requested}'"
    fi
    ;;
  esac

  if [ "${resolved}" = "false" ] && [ -n "${SPIRE_DEV_MANIFESTS_DIR}" ]; then
    log_fail "manifests-dir requires the controller-manager, but controller-manager is false. Set controller-manager: true, or express the entries with the entries input instead."
  fi

  SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED="${resolved}"
  export SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED
}

# host_apply_entries <instance> <default-parent-id>
#
# Renders the caller's entries into whichever representation the deployment can
# consume, then waits until they exist. Both inputs may be combined: a manifests
# directory is copied as-is, and entries from the simple schema are rendered
# alongside it.
host_apply_entries() {
  local instance="$1"
  local default_parent="$2"
  local server_sock manifest_dir
  server_sock="$(server_socket "${instance}")"
  manifest_dir="$(static_manifest_dir "${instance}")"

  log_group "Creating registration entries"

  local combined
  combined="$(work_dir)/entries-input.yaml"
  entries_collect "${SPIRE_DEV_ENTRIES}" "${SPIRE_DEV_ENTRIES_FILE}" "${combined}"

  local have_manifests=0
  [ -n "${SPIRE_DEV_MANIFESTS_DIR}" ] && have_manifests=1

  if is_true "${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED}"; then
    # Trust domain left as a placeholder: the controller-manager is configured
    # with expandEnvStaticManifests and systemd supplies the value.
    local canonical
    canonical="$(entries_normalize "${combined}" \
      "${ENTRIES_TRUST_DOMAIN_PLACEHOLDER}" \
      "spiffe://${ENTRIES_TRUST_DOMAIN_PLACEHOLDER}/agent/${SPIRE_DEV_NODE_ID}")"

    local rendered
    rendered="$(work_dir)/manifests"
    rm -rf "${rendered}"
    entries_to_static_manifests "${canonical}" "${rendered}"

    if [ "${have_manifests}" -eq 1 ]; then
      [ -d "${SPIRE_DEV_MANIFESTS_DIR}" ] ||
        log_fail "manifests-dir is not a directory: ${SPIRE_DEV_MANIFESTS_DIR}"
      log_info "copying manifests from ${SPIRE_DEV_MANIFESTS_DIR}"
      # Copied into the work dir first so the caller's checkout is never the
      # thing being installed from, and so both sources land together.
      find "${SPIRE_DEV_MANIFESTS_DIR}" -maxdepth 1 -type f \
        \( -name '*.yaml' -o -name '*.yml' \) -exec cp {} "${rendered}/" \;
    fi

    local have_entries=0
    if [ -n "$(ls -A "${rendered}" 2>/dev/null)" ]; then
      sudo mkdir -p "${manifest_dir}"
      sudo cp "${rendered}"/*.y*ml "${manifest_dir}/"
      log_info "installed $(find "${rendered}" -type f | wc -l | tr -d ' ') manifest(s) into ${manifest_dir}"
      have_entries=1
    else
      log_warn "no entries were supplied, so the controller-manager will create none and no workload will be issued an SVID. Use the entries, entries-file or manifests-dir input."
    fi

    log_info "starting $(controller_manager_unit "${instance}")"
    sudo systemctl restart "$(controller_manager_unit "${instance}")" ||
      log_fail "could not start $(controller_manager_unit "${instance}")"
    if ! wait_for_systemd_unit "$(controller_manager_unit "${instance}")"; then
      dump_unit_failure "$(controller_manager_unit "${instance}")"
      log_fail "the controller-manager did not become active"
    fi

    # Gate on the entries actually appearing: the controller-manager reconciles
    # asynchronously, so a caller's next step would otherwise race it.
    local id
    while read -r id; do
      [ -z "${id}" ] && continue
      wait_for_entry "${server_sock}" "${id}" ||
        log_fail "the controller-manager did not create an entry for ${id}"
    done < <(printf '%s' "${canonical}" | jq -r '.[].spiffeID' |
      sed "s|\${SPIFFE_TRUST_DOMAIN}|${SPIRE_DEV_TRUST_DOMAIN}|g")

    if [ "${have_entries}" -eq 0 ]; then
      log_endgroup
      return 0
    fi
  else
    local canonical
    canonical="$(entries_normalize "${combined}" \
      "${SPIRE_DEV_TRUST_DOMAIN}" "${default_parent}")"

    local count
    count="$(printf '%s' "${canonical}" | jq 'length')"
    if [ "${count}" -eq 0 ]; then
      # Worth saying plainly: SPIRE has no default identity, so with no entries
      # every workload gets PermissionDenied. That is a usable outcome only if the
      # caller intends to create entries themselves from the outputs.
      log_warn "no entries were supplied, so no workload will be issued an SVID. Use the entries, entries-file or manifests-dir input, or create entries yourself with the server-socket-path output."
      log_endgroup
      return 0
    fi

    log_info "creating ${count} entry/entries with the spire-server CLI:"
    entries_summary "${canonical}"

    local data_file
    data_file="$(work_dir)/entries.json"
    entries_to_server_json "${canonical}" "${data_file}"

    # A re-run of the same job is expected to be a no-op rather than a failure,
    # so an entry that already exists is not an error. Any other failure is.
    local output rc=0
    output="$(sudo spire-server entry create -socketPath "${server_sock}" \
      -data "${data_file}" 2>&1)" || rc=$?
    printf '%s\n' "${output}"
    if [ "${rc}" -ne 0 ]; then
      if printf '%s' "${output}" | grep -qi 'similar entry already exists'; then
        log_info "some entries already existed; continuing"
      else
        log_fail "could not create registration entries"
      fi
    fi

    local id
    while read -r id; do
      [ -z "${id}" ] && continue
      wait_for_entry "${server_sock}" "${id}" ||
        log_fail "entry ${id} was not found after creation"
    done < <(printf '%s' "${canonical}" | jq -r '.[].spiffeID')
  fi

  log_endgroup

  host_wait_for_entry_propagation "${instance}" "${default_parent}"
}

# host_wait_for_entry_propagation <instance> <agent-spiffe-id>
#
# Waits until the agent can actually issue an SVID, not merely until the entries
# exist on the server.
#
# Those are different things. The agent serves from a cache it refreshes from the
# server on an interval (5s by default), so an entry can exist server-side while a
# workload asking for it still gets "PermissionDenied: no identity issued". Without
# this gate the action returns during that window and the caller's very next step
# loses the race -- which is exactly the kind of failure that looks like a
# misconfigured entry rather than a timing problem.
#
# The gate is a throwaway entry created last and matched by a transient unit this
# action controls. Because the agent syncs all of its entries in one pass, the probe
# becoming issuable proves the sync happened after every entry above it was created.
# Probing a caller's own entry instead would mean guessing which of their selectors
# this action is able to satisfy.
host_wait_for_entry_propagation() {
  local instance="$1"
  local parent_id="$2"
  local server_sock agent_sock
  server_sock="$(server_socket "${instance}")"
  agent_sock="$(agent_socket "${instance}")"

  local probe_unit="spire-dev-action-probe"
  local probe_entry_id="spire-dev-action-ready-probe"
  local probe_id="spiffe://${SPIRE_DEV_TRUST_DOMAIN}/spire-dev-action/ready-probe"

  log_group "Waiting for entries to reach the agent"

  local probe_json
  probe_json="$(work_dir)/ready-probe.json"
  # A pinned entry_id, so the probe can be deleted deterministically rather than by
  # searching for it.
  cat >"${probe_json}" <<EOF
{
  "entries": [
    {
      "entry_id": "${probe_entry_id}",
      "spiffe_id": "${probe_id}",
      "parent_id": "${parent_id}",
      "selectors": [{"type": "systemd", "value": "id:${probe_unit}.service"}]
    }
  ]
}
EOF

  local output rc=0
  output="$(sudo spire-server entry create -socketPath "${server_sock}" \
    -data "${probe_json}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ] &&
    ! printf '%s' "${output}" | grep -qi 'similar entry already exists'; then
    log_warn "could not create the readiness probe entry; skipping the propagation check"
    printf '%s\n' "${output}" | sed 's/^/  /'
    log_endgroup
    return 0
  fi

  rc=0
  wait_for_workload_jwt "${probe_unit}" "${agent_sock}" spire-dev-action-probe || rc=$?

  # Removed either way: an entry nothing should match must not outlive the check.
  sudo spire-server entry delete -socketPath "${server_sock}" \
    -entryID "${probe_entry_id}" >/dev/null 2>&1 || true

  if [ "${rc}" -ne 0 ]; then
    log_fail "entries exist on the server but the agent did not become able to issue SVIDs. The deployment is not usable; check the agent log with the diagnostics action."
  fi

  log_info "the agent is serving entries; workloads can be issued SVIDs"
  log_endgroup
}

# host_publish_outputs <instance> <agent-id> — expose the paths a caller needs to
# talk to this deployment, and write the trust bundle to a file for anything that
# needs to verify SVIDs out of band.
host_publish_outputs() {
  local instance="$1"
  local agent_id="$2"
  local server_sock agent_sock bundle_file
  server_sock="$(server_socket "${instance}")"
  agent_sock="$(agent_socket "${instance}")"
  bundle_file="$(work_dir)/bundle.pem"

  # The redirect runs as the invoking user, not under sudo, which is what is
  # wanted: sudo is only needed to read the root-owned server socket, and the
  # bundle lands in the work dir where the caller can read it.
  # shellcheck disable=SC2024
  sudo spire-server bundle show -socketPath "${server_sock}" >"${bundle_file}" 2>/dev/null ||
    log_warn "could not write the trust bundle to ${bundle_file}"

  log_group "Deployment summary"
  log_set_output trust-domain "${SPIRE_DEV_TRUST_DOMAIN}"
  log_set_output agent-socket-path "${agent_sock}"
  log_set_output server-socket-path "${server_sock}"
  log_set_output admin-socket-path "$(agent_admin_socket "${instance}")"
  log_set_output bundle-file "${bundle_file}"
  log_set_output agent-spiffe-id "${agent_id}"
  log_set_output work-dir "${SPIRE_DEV_WORK_DIR}"
  if is_true "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER}"; then
    log_set_output oidc-discovery-url "http://127.0.0.1:${SPIRE_DEV_OIDC_PORT}"
  else
    log_set_output oidc-discovery-url ""
  fi

  # SPIFFE_ENDPOINT_SOCKET is the standard variable every SPIFFE library reads,
  # so exporting it means a caller's application usually needs no configuration
  # at all.
  log_export SPIFFE_ENDPOINT_SOCKET "unix://${agent_sock}"

  log_summary "### SPIRE deployed (host mode)"
  log_summary ""
  log_summary "| | |"
  log_summary "|---|---|"
  log_summary "| Trust domain | \`${SPIRE_DEV_TRUST_DOMAIN}\` |"
  log_summary "| Workload API socket | \`${agent_sock}\` |"
  log_summary "| Server socket | \`${server_sock}\` |"
  log_summary "| Agent SPIFFE ID | \`${agent_id}\` |"
  log_summary "| Controller manager | \`${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED}\` |"
  log_endgroup
}
