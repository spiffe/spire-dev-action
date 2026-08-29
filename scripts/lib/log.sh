#!/usr/bin/env bash
# Logging and CI-integration shim.
#
# This is the ONLY file in the tree that knows about GitHub Actions. Everything
# else calls these functions, so porting to another CI system means replacing
# this file and nothing else. Every function degrades to plain stdout (or a file
# under the work dir) when the GitHub environment variables are absent, so the
# scripts remain runnable from a plain shell.
#
# Only GitHub Actions is supported today. GitLab support is deliberately
# deferred; do not add a second backend here without also adding a way to
# select between them.

# Guard against double-sourcing; these files are sourced from several layers.
[ -n "${_SPIRE_DEV_LOG_SH:-}" ] && return 0
_SPIRE_DEV_LOG_SH=1

# Set by lib/common.sh, but default it here so log.sh can stand alone.
: "${SPIRE_DEV_WORK_DIR:=${RUNNER_TEMP:-/tmp}/spire-dev-action.$$}"

# Where step-summary style output accumulates. Under Actions this is the real
# summary file; otherwise it is a file in the work dir that the diagnostics
# action can still upload.
_log_summary_file() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "${GITHUB_STEP_SUMMARY}"
  else
    mkdir -p "${SPIRE_DEV_WORK_DIR}"
    echo "${SPIRE_DEV_WORK_DIR}/summary.md"
  fi
}

_log_in_github() {
  [ -n "${GITHUB_ACTIONS:-}" ]
}

# log_group <title> / log_endgroup — collapsible section.
log_group() {
  if _log_in_github; then
    echo "::group::$*"
  else
    echo "==> $*"
  fi
}

log_endgroup() {
  if _log_in_github; then
    echo "::endgroup::"
  fi
}

log_info() {
  echo "$*"
}

log_notice() {
  if _log_in_github; then
    echo "::notice::$*"
  else
    echo "NOTICE: $*"
  fi
}

log_warn() {
  if _log_in_github; then
    echo "::warning::$*"
  else
    echo "WARNING: $*" >&2
  fi
}

log_error() {
  if _log_in_github; then
    echo "::error::$*"
  else
    echo "ERROR: $*" >&2
  fi
}

# log_fail <message...> — report and exit non-zero.
log_fail() {
  log_error "$@"
  exit 1
}

# log_mask <value> — ask the CI system to redact a value from its logs. Callers
# must still avoid tracing the value themselves (see log_no_trace).
log_mask() {
  [ -z "${1:-}" ] && return 0
  if _log_in_github; then
    echo "::add-mask::$1"
  fi
}

# log_set_output <name> <value> — publish an action output.
#
# Uses the heredoc form so values containing newlines or '=' survive intact.
log_set_output() {
  local name="$1"
  local value="${2:-}"
  log_info "output: ${name}=${value}"
  [ -z "${GITHUB_OUTPUT:-}" ] && return 0
  local delim="SPIRE_DEV_EOF_$$"
  {
    echo "${name}<<${delim}"
    echo "${value}"
    echo "${delim}"
  } >>"${GITHUB_OUTPUT}"
}

# log_export <name> <value> — publish an environment variable to later steps.
log_export() {
  local name="$1"
  local value="${2:-}"
  export "${name}=${value}"
  [ -z "${GITHUB_ENV:-}" ] && return 0
  local delim="SPIRE_DEV_EOF_$$"
  {
    echo "${name}<<${delim}"
    echo "${value}"
    echo "${delim}"
  } >>"${GITHUB_ENV}"
}

# log_add_path <dir> — prepend a directory to PATH for later steps.
log_add_path() {
  local dir="$1"
  export PATH="${dir}:${PATH}"
  [ -n "${GITHUB_PATH:-}" ] && echo "${dir}" >>"${GITHUB_PATH}"
  return 0
}

# log_summary <markdown...> — append a line to the run summary.
log_summary() {
  local file
  file="$(_log_summary_file)"
  echo "$*" >>"${file}"
}

# log_summary_file <path> — append a file's contents to the run summary,
# truncating the summary if it would grow past the 1 MiB limit that GitHub
# enforces on step summaries.
log_summary_file() {
  local src="$1"
  local file
  file="$(_log_summary_file)"
  [ -f "${src}" ] || return 0
  cat "${src}" >>"${file}"
  log_summary_truncate
}

# log_summary_truncate — keep the summary under the 1 MiB cap. GitHub rejects
# the whole summary if it is oversized, so losing the tail beats losing all of
# it.
log_summary_truncate() {
  local max_bytes=1048576
  local file size
  file="$(_log_summary_file)"
  [ -f "${file}" ] || return 0
  size="$(wc -c <"${file}" | tr -d ' ')"
  if [ "${size}" -gt "${max_bytes}" ]; then
    truncate -s $((max_bytes - 14)) "${file}"
    echo "truncated..." >>"${file}"
  fi
}

# log_no_trace <command...> — run a command with shell tracing suppressed, for
# anything that handles a join token or other secret. Restores the previous
# xtrace setting afterwards.
log_no_trace() {
  local restore=0
  case "$-" in
  *x*) restore=1 ;;
  esac
  set +x
  "$@"
  local rc=$?
  [ "${restore}" -eq 1 ] && set -x
  return "${rc}"
}
