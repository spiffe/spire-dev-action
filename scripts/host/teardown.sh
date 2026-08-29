#!/usr/bin/env bash
# Host mode teardown.
#
# Opt-in, and never automatic: the whole point of the action is to leave SPIRE
# running for the steps that follow it. This exists for a self-hosted runner that
# is reused between jobs.
#
# Stops the units and removes the configuration this action wrote. It deliberately
# does not uninstall the packages: that is slow, and a reused runner benefits from
# the apt cache being warm.

[ -n "${_SPIRE_DEV_HOST_TEARDOWN_SH:-}" ] && return 0
_SPIRE_DEV_HOST_TEARDOWN_SH=1

_host_teardown_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./paths.sh
. "${_host_teardown_dir}/paths.sh"

host_teardown() {
  local instance="${SPIRE_DEV_INSTANCE}"

  log_group "Stopping SPIRE"
  local unit
  while read -r unit; do
    [ -z "${unit}" ] && continue
    # Failures are ignored: a unit that was never started is the normal case for
    # the optional components, and teardown must not fail the job.
    sudo systemctl stop "${unit}" 2>/dev/null || true
    sudo systemctl reset-failed "${unit}" 2>/dev/null || true
    log_info "stopped ${unit}"
  done < <(host_units)
  log_endgroup

  log_group "Removing generated configuration"
  local path
  for path in \
    "$(server_config "${instance}")" \
    "$(agent_config "${instance}")" \
    "$(controller_manager_config "${instance}")" \
    "$(server_env "${instance}")" \
    "$(agent_env "${instance}")" \
    "$(controller_manager_env "${instance}")" \
    "$(static_manifest_dir "${instance}")" \
    "/etc/spire/oidc-discovery-provider/${instance}.conf" \
    "/etc/spire/oidc-discovery-provider/${instance}.env" \
    "$(identity_exchange_dir "${instance}")" \
    "/etc/spire/identity-exchange/${instance}.json"; do
    if [ -e "${path}" ]; then
      sudo rm -rf "${path}"
      log_info "removed ${path}"
    fi
  done

  # State directories, so a later run starts with a fresh datastore and keys
  # rather than an agent trying to reuse an SVID from a server that no longer has
  # the same CA.
  sudo rm -rf \
    "/var/lib/spire/server/${instance}" \
    "/var/lib/spire/agent/${instance}" \
    "/var/lib/spire/agent/$(six_instance)" \
    "/var/lib/spire/controller-manager/${instance}" \
    "/var/lib/spire/oidc-discovery-provider/${instance}" \
    "/var/lib/spire/identity-exchange/${instance}" 2>/dev/null || true

  # The unit this action installed itself, unlike the package-shipped ones.
  sudo rm -f /etc/systemd/system/spiffe-oidc-discovery-provider@.service
  sudo systemctl daemon-reload 2>/dev/null || true
  log_endgroup

  log_info "host teardown complete; the SPIRE packages were left installed"
}
