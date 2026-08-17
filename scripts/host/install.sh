#!/usr/bin/env bash
# Installs the SPIRE deb packages from the spire-examples apt repository.

[ -n "${_SPIRE_DEV_HOST_INSTALL_SH:-}" ] && return 0
_SPIRE_DEV_HOST_INSTALL_SH=1

_host_install_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./paths.sh
. "${_host_install_dir}/paths.sh"

# host_assert_supported — fail early and clearly rather than part way through a
# sequence of sudo commands.
host_assert_supported() {
  [ "$(uname -s)" = "Linux" ] ||
    log_fail "host mode requires Linux; got $(uname -s). Use mode: k8s, or run this on a Linux runner."
  command -v systemctl >/dev/null 2>&1 ||
    log_fail "host mode requires systemd; systemctl was not found."
  command -v apt-get >/dev/null 2>&1 ||
    log_fail "host mode installs deb packages and requires apt-get. Only Debian and Ubuntu hosts are supported."
  require_cmd curl sudo
}

# host_assert_allowed — host mode installs packages, writes under /etc and starts
# services, so it must not run against a machine someone cares about.
#
# The reference test suites guarded this by refusing to run unless GITHUB_JOB was
# set, which made them unusable anywhere else. This is an explicit opt-in
# instead: CI is assumed disposable, anything else has to say so.
host_assert_allowed() {
  if is_true "${SPIRE_DEV_ALLOW_HOST_MODIFICATION:-}"; then
    return 0
  fi
  if in_ci; then
    return 0
  fi
  log_error "host mode installs packages, writes under /etc and starts systemd services."
  log_error "It is meant for a disposable CI runner and does not clean up after itself."
  log_fail "Refusing to modify this host. Set allow-host-modification: true (or SPIRE_DEV_ALLOW_HOST_MODIFICATION=1) if this machine is disposable."
}

# host_install_packages — add the apt repository and install the packages the
# enabled components need.
host_install_packages() {
  log_group "Installing SPIRE packages"

  local list_url="${SPIRE_DEV_SPIRE_EXAMPLES_LIST_URL}"
  [ -n "${list_url}" ] || log_fail "no deb repository URL resolved; check versions.json"

  log_info "apt source: ${list_url}"
  # The published repository is unsigned and its list file carries
  # [trusted=yes]. Acceptable for a disposable test host; called out here so it
  # is not a surprise.
  sudo mkdir -p /etc/apt/sources.list.d
  sudo curl -fsSL -o /etc/apt/sources.list.d/spire-examples.list "${list_url}" ||
    log_fail "could not fetch the spire-examples apt source list from ${list_url}"

  sudo apt-get update -o Dir::Etc::sourcelist=sources.list.d/spire-examples.list \
    -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 ||
    log_fail "apt-get update failed for the spire-examples repository"

  local packages=(spire-common spire-server spire-agent)
  is_true "${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED:-}" && packages+=(spire-controller-manager)
  is_true "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER:-}" && packages+=(spiffe-oidc-discovery-provider)
  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE:-}"; then
    # The exchange also needs the credential composer plugin, which sets the CN
    # its x509pop selector matches on, and the server attestor its second agent
    # rebootstraps through. See scripts/host/six.sh.
    packages+=(
      spire-identity-exchange-server
      spire-credentialcomposer-identity-exchange
      spire-server-attestor-spiffe-workload-api
    )
  fi

  # A pinned package version applies to every package, since they are built and
  # published together from one source version.
  local version_suffix=""
  if [ -n "${SPIRE_DEV_SPIRE_EXAMPLES_PACKAGE_VERSION:-}" ]; then
    version_suffix="=${SPIRE_DEV_SPIRE_EXAMPLES_PACKAGE_VERSION}"
  fi

  local to_install=()
  local pkg
  for pkg in "${packages[@]}"; do
    to_install+=("${pkg}${version_suffix}")
  done

  log_info "installing: ${to_install[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${to_install[@]}" || log_fail "could not install the SPIRE packages"

  log_info "installed versions:"
  dpkg-query -W -f='  ${Package} ${Version}\n' "${packages[@]}" 2>/dev/null || true

  log_endgroup
}
