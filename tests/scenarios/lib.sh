#!/usr/bin/env bash
# Shared helpers for the scenario tests.
#
# Scenarios call scripts/spire-dev.sh directly rather than going through
# action.yml, because a composite action cannot be invoked from a script. That is
# the point of keeping the implementation CI-agnostic; the workflow separately
# exercises action.yml itself so the input wiring is not left untested.
#
# These scenarios deploy real SPIRE. Host ones modify the machine they run on and
# are meant only for a disposable CI runner.

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
SPIRE_DEV_ROOT="$(cd "${SCENARIO_DIR}/../../../.." && pwd)"
export SPIRE_DEV_ROOT

# A work dir per scenario, so the diagnostics step can find it and so two
# scenarios in one job cannot collide.
SPIRE_DEV_WORK_DIR="${RUNNER_TEMP:-/tmp}/spire-dev-action/$(basename "${SCENARIO_DIR}")"
export SPIRE_DEV_WORK_DIR

# shellcheck source=../../scripts/lib/wait.sh
. "${SPIRE_DEV_ROOT}/scripts/lib/wait.sh"

SCENARIO_FAILURES=0

scenario_begin() {
  log_info "=============================================="
  log_info "scenario: $(basename "${SCENARIO_DIR}")"
  log_info "work dir: ${SPIRE_DEV_WORK_DIR}"
  log_info "=============================================="
}

# spire_dev <command> — run the action's entrypoint.
spire_dev() {
  "${SPIRE_DEV_ROOT}/scripts/spire-dev.sh" "$@"
}

# check <description> <command...> — the command must succeed.
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   ${description}"
  else
    echo "FAIL ${description}" >&2
    echo "     command: $*" >&2
    "$@" 2>&1 | sed 's/^/     /' >&2 || true
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  fi
}

# check_equals <description> <expected> <actual>
check_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "ok   ${description}"
  else
    echo "FAIL ${description}" >&2
    echo "     expected: ${expected}" >&2
    echo "     actual:   ${actual}" >&2
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  fi
}

# check_contains <description> <haystack> <needle>
check_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    echo "ok   ${description}"
  else
    echo "FAIL ${description}" >&2
    echo "     expected to contain: ${needle}" >&2
    echo "     actual: ${haystack}" >&2
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  fi
}

# check_absent <description> <haystack> <needle>
#
# Fails if the haystack is empty as well as if it contains the needle: a negative
# assertion against nothing passes for the wrong reason, which is exactly how a
# broken lookup hides.
check_absent() {
  local description="$1"
  local haystack="$2"
  local needle="$3"
  if [ -z "${haystack}" ]; then
    echo "FAIL ${description}: nothing to check against (the lookup returned empty)" >&2
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  elif printf '%s' "${haystack}" | grep -qF "${needle}"; then
    echo "FAIL ${description}" >&2
    echo "     unexpectedly found: ${needle}" >&2
    printf '%s\n' "${haystack}" | grep -F "${needle}" | sed 's/^/     /' >&2
    SCENARIO_FAILURES=$((SCENARIO_FAILURES + 1))
  else
    echo "ok   ${description}"
  fi
}

scenario_end() {
  echo
  if [ "${SCENARIO_FAILURES}" -ne 0 ]; then
    echo "${SCENARIO_FAILURES} check(s) failed in $(basename "${SCENARIO_DIR}")" >&2
    exit 1
  fi
  echo "scenario $(basename "${SCENARIO_DIR}") passed"
}
