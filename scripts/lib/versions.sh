#!/usr/bin/env bash
# Turns versions.json into SPIRE_DEV_<UPPER_SNAKE> environment variables.
#
# Follows the pinned-dependency pattern from helm-charts-hardened's
# .github/scripts/parse-versions.sh, generalized to any nesting depth so adding
# a key to versions.json needs no change here. An already-set variable always
# wins, which is how action inputs override the pinned defaults.

[ -n "${_SPIRE_DEV_VERSIONS_SH:-}" ] && return 0
_SPIRE_DEV_VERSIONS_SH=1

_versions_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "${_versions_lib_dir}/common.sh"

# load_versions [file] — source the pinned versions into the environment.
load_versions() {
  local file="${1:-${SPIRE_DEV_VERSIONS_FILE:-${SPIRE_DEV_ROOT}/versions.json}}"
  require_cmd jq
  [ -f "${file}" ] || log_fail "versions file not found: ${file}"

  # Name/value pairs rather than eval'able assignments: values contain '${...}'
  # references that must survive until every pin is loaded, and quoting them
  # safely through eval is more fragile than just reading them.
  #
  # "comment" keys document the file and must not become variables.
  local pairs name value
  pairs="$(
    jq -r '
      paths(scalars) as $p
      | select(all($p[]; . != "comment"))
      | ($p | map(
          tostring
          | gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)")
          | ascii_upcase
          | gsub("[^A-Z0-9]"; "_")
        ) | join("_")) as $name
      | "SPIRE_DEV_\($name)\t\(getpath($p) | tostring)"
    ' "${file}"
  )" || log_fail "could not parse ${file}"

  while IFS=$'\t' read -r name value; do
    [ -z "${name}" ] && continue
    # An already-set variable wins, so action inputs override the pins.
    if [ -z "${!name:-}" ]; then
      export "${name}=${value}"
    fi
  done <<<"${pairs}"

  # deb_arch is needed to expand the deb list URL, and is a property of the
  # runner rather than of the pinned versions, so it is resolved here. Host mode
  # is Debian-only; on any other platform leave it unset rather than failing,
  # since k8s mode and the entry renderer do not need it.
  if [ -z "${SPIRE_DEV_DEB_ARCH:-}" ] && [ "$(uname -s)" = "Linux" ]; then
    SPIRE_DEV_DEB_ARCH="$(deb_arch)"
    export SPIRE_DEV_DEB_ARCH
  fi

  # listUrl references other pinned values, so expand it once they are all set.
  if [ -n "${SPIRE_DEV_SPIRE_EXAMPLES_LIST_URL:-}" ]; then
    SPIRE_DEV_SPIRE_EXAMPLES_LIST_URL="$(
      _expand_known_vars "${SPIRE_DEV_SPIRE_EXAMPLES_LIST_URL}"
    )"
    export SPIRE_DEV_SPIRE_EXAMPLES_LIST_URL
  fi
}

# _expand_known_vars <string> — expand ${SPIRE_DEV_*} references without the
# arbitrary-code-execution surface of eval on a whole string.
_expand_known_vars() {
  local input="$1"
  local name value
  while [[ "${input}" =~ \$\{(SPIRE_DEV_[A-Z0-9_]+)\} ]]; do
    name="${BASH_REMATCH[1]}"
    value="${!name:-}"
    input="${input//\$\{${name}\}/${value}}"
  done
  printf '%s' "${input}"
}

# print_versions — log the resolved pins, so a failed run records exactly what
# it installed.
print_versions() {
  log_group "Resolved versions"
  local var
  for var in $(compgen -v SPIRE_DEV_ | sort); do
    case "${var}" in
    SPIRE_DEV_WORK_DIR | SPIRE_DEV_ROOT) continue ;;
    esac
    log_info "  ${var}=${!var}"
  done
  log_endgroup
}
