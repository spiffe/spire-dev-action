#!/usr/bin/env bash
# Filesystem layout of the spire-examples deb packages.
#
# Every path here is dictated by the packages, not chosen by this action. The
# unit files (spire-{server,agent,controller-manager}@.service) and the start.sh
# wrappers in /usr/libexec/spire decide them; these functions exist so the layout
# is written down once and the deploy, diagnostics and teardown paths cannot
# disagree about it.
#
# Sourced by host mode and by the diagnostics and teardown actions.

[ -n "${_SPIRE_DEV_HOST_PATHS_SH:-}" ] && return 0
_SPIRE_DEV_HOST_PATHS_SH=1

_host_paths_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${_host_paths_dir}/../lib/common.sh"

: "${SPIRE_DEV_INSTANCE:=main}"

# The SIX agent runs as a second instance so that spire-identity-exchange has a
# delegated-identity socket of its own, separate from the workload API the
# caller's application uses.
six_instance() {
  echo "${SPIRE_DEV_INSTANCE}-six"
}

# --- sockets (created by the units' RuntimeDirectory) -----------------------

server_socket() {
  echo "/run/spire/server/sockets/${1:-${SPIRE_DEV_INSTANCE}}/private/api.sock"
}

agent_socket() {
  echo "/run/spire/agent/sockets/${1:-${SPIRE_DEV_INSTANCE}}/public/api.sock"
}

# The unit sets SPIRE_AGENT_ADMIN_ADDRESS to this path under /var/run, which is
# the same directory as /run on any systemd host.
agent_admin_socket() {
  echo "/var/run/spire/agent/sockets/${1:-${SPIRE_DEV_INSTANCE}}/private/admin.sock"
}

# --- configuration ---------------------------------------------------------

# start.sh prefers <instance>/config over <instance>.conf over default.conf, so
# writing the directory form leaves the package defaults untouched underneath.
server_config() {
  echo "/etc/spire/server/${1:-${SPIRE_DEV_INSTANCE}}/config"
}

# The agent unit's ExecStartPre copies <instance>.conf when present, so unlike
# the server there is no directory form.
agent_config() {
  echo "/etc/spire/agent/${1:-${SPIRE_DEV_INSTANCE}}.conf"
}

controller_manager_config() {
  echo "/etc/spire/controller-manager/${1:-${SPIRE_DEV_INSTANCE}}.conf"
}

# Directory the controller-manager watches for ClusterStaticEntry manifests.
static_manifest_dir() {
  echo "/etc/spire/server/${1:-${SPIRE_DEV_INSTANCE}}/manifests"
}

# --- environment files -----------------------------------------------------
#
# The units stack EnvironmentFile=- entries and the last one wins:
#   /etc/spiffe/default-trust-domain.env
#   /etc/spire/<component>/default.env
#   /etc/spire/<component>/<instance>.env      <- what this action writes
#   /etc/spire/<component>/<instance>/env
# Writing the per-instance file is how configuration is overridden without
# touching any package-shipped file.

trust_domain_env() {
  echo "/etc/spiffe/default-trust-domain.env"
}

server_env() {
  echo "/etc/spire/server/${1:-${SPIRE_DEV_INSTANCE}}.env"
}

agent_env() {
  echo "/etc/spire/agent/${1:-${SPIRE_DEV_INSTANCE}}.env"
}

controller_manager_env() {
  echo "/etc/spire/controller-manager/${1:-${SPIRE_DEV_INSTANCE}}.env"
}

# --- units -----------------------------------------------------------------

server_unit() {
  echo "spire-server@${1:-${SPIRE_DEV_INSTANCE}}"
}

agent_unit() {
  echo "spire-agent@${1:-${SPIRE_DEV_INSTANCE}}"
}

controller_manager_unit() {
  echo "spire-controller-manager@${1:-${SPIRE_DEV_INSTANCE}}"
}

oidc_unit() {
  echo "spiffe-oidc-discovery-provider@${1:-${SPIRE_DEV_INSTANCE}}"
}

identity_exchange_unit() {
  echo "spire-identity-exchange-server@${1:-${SPIRE_DEV_INSTANCE}}"
}

# host_units — every unit this action may have started, in the order they should
# be reported or stopped.
host_units() {
  local instance="${SPIRE_DEV_INSTANCE}"
  server_unit "${instance}"
  controller_manager_unit "${instance}"
  agent_unit "${instance}"
  agent_unit "$(six_instance)"
  identity_exchange_unit "${instance}"
  oidc_unit "${instance}"
}

# --- identity exchange -----------------------------------------------------

identity_exchange_dir() {
  echo "/etc/spire/identity-exchange/${1:-${SPIRE_DEV_INSTANCE}}"
}

identity_exchange_cert_dir() {
  echo "$(identity_exchange_dir "${1:-${SPIRE_DEV_INSTANCE}}")/certs"
}
