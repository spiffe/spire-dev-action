#!/usr/bin/env bash
# Optional: the SPIFFE OIDC Discovery Provider on the host.
#
# The spiffe-oidc-discovery-provider deb ships only the binary, so unlike every
# other component here the unit and configuration come from this action
# (conf/host/spiffe-oidc-discovery-provider@.service and
# conf/host/oidc-discovery-provider.conf).

[ -n "${_SPIRE_DEV_HOST_OIDC_SH:-}" ] && return 0
_SPIRE_DEV_HOST_OIDC_SH=1

_host_oidc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./configure.sh
. "${_host_oidc_dir}/configure.sh"
# shellcheck source=../lib/wait.sh
. "${_host_oidc_dir}/../lib/wait.sh"

# host_deploy_oidc <instance>
host_deploy_oidc() {
  local instance="$1"
  local addr="127.0.0.1:${SPIRE_DEV_OIDC_PORT}"

  log_group "Starting the OIDC discovery provider"

  command -v /bin/spiffe-oidc-discovery-provider >/dev/null 2>&1 ||
    log_fail "/bin/spiffe-oidc-discovery-provider is missing; the spiffe-oidc-discovery-provider package did not install as expected"

  write_root_file "/etc/spire/oidc-discovery-provider/${instance}.env" <<EOF
SPIRE_LOG_LEVEL=${SPIRE_DEV_LOG_LEVEL}
SPIRE_OIDC_ADDR=${addr}
SPIRE_SERVER_PRIVATE_SOCKET=$(server_socket "${instance}")
EOF

  write_root_file "/etc/spire/oidc-discovery-provider/${instance}.conf" \
    <"${SPIRE_DEV_ROOT}/conf/host/oidc-discovery-provider.conf"

  write_root_file \
    "/etc/systemd/system/spiffe-oidc-discovery-provider@.service" \
    <"${SPIRE_DEV_ROOT}/conf/host/spiffe-oidc-discovery-provider@.service"

  sudo systemctl daemon-reload
  sudo systemctl restart "$(oidc_unit "${instance}")" ||
    log_fail "could not start $(oidc_unit "${instance}")"

  wait_for_systemd_unit "$(oidc_unit "${instance}")" ||
    log_fail "the OIDC discovery provider did not become active"

  # The discovery document is the thing callers actually consume, so gate on it
  # rather than on the process being up.
  wait_for_url "http://${addr}/.well-known/openid-configuration" 60 ||
    log_fail "the OIDC discovery provider did not serve its discovery document"

  log_info "OIDC discovery available at http://${addr}"
  log_endgroup
}
