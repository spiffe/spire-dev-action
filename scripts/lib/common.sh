#!/usr/bin/env bash
# Shared helpers with no SPIRE knowledge: work directories, tool checks,
# polling, host addressing, boolean parsing.

[ -n "${_SPIRE_DEV_COMMON_SH:-}" ] && return 0
_SPIRE_DEV_COMMON_SH=1

_common_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
. "${_common_lib_dir}/log.sh"

# Root of this action's checkout, derived from this file's location rather than
# from the caller's relative depth.
SPIRE_DEV_ROOT="$(cd "${_common_lib_dir}/../.." && pwd)"
export SPIRE_DEV_ROOT

# Every generated file lives here. Nothing is ever written into the caller's
# checkout, so repeated runs stay idempotent and nothing dirties their tree.
: "${SPIRE_DEV_WORK_DIR:=${RUNNER_TEMP:-/tmp}/spire-dev-action.$$}"
export SPIRE_DEV_WORK_DIR

# work_dir [subdir] — ensure the work dir (or a subdirectory) exists and echo it.
work_dir() {
  local dir="${SPIRE_DEV_WORK_DIR}"
  [ -n "${1:-}" ] && dir="${dir}/$1"
  mkdir -p "${dir}"
  echo "${dir}"
}

# require_cmd <cmd> [cmd...] — fail with one combined message listing every
# missing tool, rather than failing once per tool across several runs.
require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log_fail "required tool(s) not found on PATH: ${missing[*]}"
  fi
}

# is_true <value> — accept the spellings a YAML action input can produce.
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes | on) return 0 ;;
  *) return 1 ;;
  esac
}

# is_false <value> — explicitly false, as distinct from "auto" or unset.
is_false() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
  0 | false | no | off) return 0 ;;
  *) return 1 ;;
  esac
}

# in_ci — true when running under a recognized CI system. Used to decide
# whether host-modifying operations are allowed without an explicit opt-in.
in_ci() {
  [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]
}

# poll <timeout_seconds> <interval_seconds> <description> <command...>
#
# Runs the command until it succeeds, or fails after the timeout. Replaces the
# hand-rolled counter loops that were copied across every test suite in the
# reference repos; those swallowed the command's output and used a fixed 30x1s
# budget, so a slow step looked identical to a broken one.
poll() {
  local timeout="$1"
  local interval="$2"
  local description="$3"
  shift 3

  local deadline_reached=0
  local elapsed=0
  local last_output
  local last_rc=0

  while :; do
    if last_output="$("$@" 2>&1)"; then
      log_info "ok: ${description} (after ${elapsed}s)"
      return 0
    else
      # Must be read inside the else branch: an if statement whose condition
      # failed and which has no else exits 0, masking the real status.
      last_rc=$?
    fi
    # Compare before sleeping so a zero timeout still makes one attempt.
    if [ "${deadline_reached}" -eq 1 ]; then
      break
    fi
    sleep "${interval}"
    # Bash arithmetic on a possibly fractional interval would fail, so only
    # whole-second intervals are supported; callers all use integers.
    elapsed=$((elapsed + interval))
    if [ "${elapsed}" -ge "${timeout}" ]; then
      deadline_reached=1
    fi
  done

  log_error "timed out after ${elapsed}s waiting for ${description} (last exit ${last_rc})"
  if [ -n "${last_output}" ]; then
    log_info "last output:"
    echo "${last_output}" | sed 's/^/    /'
  fi
  return 1
}

# host_ip — the address a container or cluster node can use to reach a service
# listening on this host.
#
# The reference repos inlined `ip -4 addr show docker0 | grep -oP ...` in seven
# places, which assumes a Linux host with a docker0 bridge. This tries the
# container bridges in turn, then falls back to the address used for the default
# route, which also works for rootless docker and podman.
host_ip() {
  local iface ip

  for iface in docker0 podman0 cni-podman0; do
    if ip=$(_ip_for_iface "${iface}") && [ -n "${ip}" ]; then
      echo "${ip}"
      return 0
    fi
  done

  # Address this host would use to reach the outside world. No packets are sent.
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
    if [ -n "${ip}" ]; then
      echo "${ip}"
      return 0
    fi
  fi

  # macOS and other BSDs, where the action is not expected to deploy but where
  # helpers may still be exercised.
  if command -v route >/dev/null 2>&1; then
    iface="$(route -n get default 2>/dev/null | sed -n 's/.*interface: *\([a-z0-9]*\).*/\1/p' | head -1)"
    if [ -n "${iface}" ]; then
      ip="$(ifconfig "${iface}" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
      if [ -n "${ip}" ]; then
        echo "${ip}"
        return 0
      fi
    fi
  fi

  log_error "could not determine this host's IP address"
  return 1
}

_ip_for_iface() {
  local iface="$1"
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 addr show "${iface}" 2>/dev/null |
    sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
}

# deb_arch — the architecture component of the spire-examples apt repository
# path. The repo is published per-architecture, so this picks the directory.
deb_arch() {
  local arch
  if command -v dpkg >/dev/null 2>&1; then
    arch="$(dpkg --print-architecture)"
  else
    case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) arch="$(uname -m)" ;;
    esac
  fi
  case "${arch}" in
  amd64 | arm64) echo "${arch}" ;;
  *) log_fail "unsupported architecture '${arch}'; spire-examples publishes debs for amd64 and arm64 only" ;;
  esac
}

# split_list <value> — the entries of a comma- or newline-separated list, one per
# line, with surrounding whitespace stripped and empties dropped.
#
# A YAML action input can spell the same list either way: `a, b` on one line or a
# block scalar with one entry per line. Both reach the script as a single string,
# so both are accepted rather than making the caller guess which one works.
split_list() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# trust_domain_path <spiffe-id> — the path portion of a SPIFFE ID, or empty.
trust_domain_path() {
  printf '%s' "${1#spiffe://*/}"
}

# render_env_template <src> <dest> — expand ${VAR} references in a template.
#
# Only used for files consumed by something that cannot expand env vars itself.
# SPIRE's own configs are left unexpanded on purpose: the server and agent are
# started with -expandEnv and the controller-manager with
# expandEnvStaticManifests, so leaving ${SPIFFE_TRUST_DOMAIN} in place keeps the
# generated files readable and lets systemd's EnvironmentFile chain stay the
# single source of truth.
render_env_template() {
  local src="$1"
  local dest="$2"
  require_cmd envsubst
  envsubst <"${src}" >"${dest}"
}
