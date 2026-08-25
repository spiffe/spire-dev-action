#!/usr/bin/env bash
# Renders the host-mode SPIRE configs and checks their structure.
#
# No root, no packages, no systemd: these are text transformations, so the whole
# class of bug where a generated config is syntactically wrong is catchable here
# rather than only when a real server refuses to start.
#
# This exists because of a specific bug: the plugin blocks for
# spire-identity-exchange were injected wherever the template's marker string
# appeared, including inside the header comment that documents the marker. That put
# a CredentialComposer at top level outside plugins {}, which is invalid HCL, and the
# only symptom was the server timing out on its healthcheck with no explanation.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIRE_DEV_ROOT="$(cd "${SCRIPT_PATH}/../.." && pwd)"
export SPIRE_DEV_ROOT

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export SPIRE_DEV_WORK_DIR="${WORK}/work"

# shellcheck source=../../scripts/host/configure.sh
. "${SPIRE_DEV_ROOT}/scripts/host/configure.sh"

FAILURES=0

fail() {
  echo "FAIL $*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  echo "ok   $*"
}

# check_hcl_balanced <label> <file> — braces must pair, and every one must close.
#
# A cheap structural check, but it is exactly what the marker bug broke: the
# injected block was well-formed on its own and only wrong in where it landed.
check_hcl_balanced() {
  local label="$1" file="$2"
  local depth=0 line lineno=0 opens closes
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Comments can contain braces; strip them before counting.
    line="${line%%#*}"
    opens="${line//[^\{]/}"
    closes="${line//[^\}]/}"
    depth=$((depth + ${#opens} - ${#closes}))
    if [ "${depth}" -lt 0 ]; then
      fail "${label}: unbalanced closing brace at line ${lineno}"
      return
    fi
  done <"${file}"
  if [ "${depth}" -ne 0 ]; then
    fail "${label}: ${depth} unclosed block(s)"
    return
  fi
  ok "${label}: braces balanced"
}

# check_at_top_level <label> <file> <pattern> <expected-count>
#
# Counts occurrences of a pattern appearing at brace depth 0, which is where a
# stanza that should be nested must never show up.
count_at_depth_zero() {
  local file="$1" pattern="$2"
  local depth=0 line stripped opens closes found=0
  while IFS= read -r line; do
    stripped="${line%%#*}"
    if [ "${depth}" -eq 0 ] && printf '%s' "${stripped}" | grep -q "${pattern}"; then
      found=$((found + 1))
    fi
    opens="${stripped//[^\{]/}"
    closes="${stripped//[^\}]/}"
    depth=$((depth + ${#opens} - ${#closes}))
  done <"${file}"
  echo "${found}"
}

count_matches() {
  grep -c "$1" "$2" || true
}

for six in false true; do
  echo
  echo "== server config with identity-exchange=${six}"
  export SPIRE_DEV_IDENTITY_EXCHANGE="${six}"
  out="${WORK}/server-${six}.conf"
  render_server_config >"${out}"

  check_hcl_balanced "server (six=${six})" "${out}"

  # The marker must never survive into an installed config.
  if grep -q '@@' "${out}"; then
    fail "server (six=${six}): an unreplaced marker survived"
    grep -n '@@' "${out}" | sed 's/^/     /' >&2
  else
    ok "server (six=${six}): no unreplaced markers"
  fi

  # Nothing but the three top-level stanzas may sit at depth 0.
  for stanza in CredentialComposer NodeAttestor KeyManager DataStore; do
    n="$(count_at_depth_zero "${out}" "^[[:space:]]*${stanza}[[:space:]]")"
    if [ "${n}" -ne 0 ]; then
      fail "server (six=${six}): ${stanza} appears ${n} time(s) at top level, outside plugins {}"
    else
      ok "server (six=${six}): no ${stanza} at top level"
    fi
  done

  n="$(count_matches 'CredentialComposer' "${out}")"
  if [ "${six}" = "true" ]; then
    [ "${n}" -eq 1 ] && ok "server: exactly one CredentialComposer" ||
      fail "server: expected 1 CredentialComposer, found ${n}"
    [ "$(count_matches 'NodeAttestor "x509pop"' "${out}")" -eq 1 ] &&
      ok "server: exactly one x509pop NodeAttestor" ||
      fail "server: x509pop NodeAttestor count wrong"
    grep -q "plugin_cmd = \"${SIX_CREDENTIAL_COMPOSER}\"" "${out}" &&
      ok "server: the composer path matches the shared constant" ||
      fail "server: the composer path does not match ${SIX_CREDENTIAL_COMPOSER}"
  else
    [ "${n}" -eq 0 ] && ok "server: no CredentialComposer when six is off" ||
      fail "server: CredentialComposer present with six off"
  fi

  # The join_token attestor is what lets the agent attest at all.
  grep -q 'NodeAttestor "join_token"' "${out}" &&
    ok "server (six=${six}): join_token attestor present" ||
    fail "server (six=${six}): join_token attestor missing"

  echo
  echo "== agent config with identity-exchange=${six}"
  aout="${WORK}/agent-${six}.conf"
  render_agent_config >"${aout}"
  check_hcl_balanced "agent (six=${six})" "${aout}"
  if grep -q '@@' "${aout}"; then
    fail "agent (six=${six}): an unreplaced marker survived"
  else
    ok "agent (six=${six}): no unreplaced markers"
  fi
  if [ "${six}" = "true" ]; then
    grep -q 'authorized_delegates = \["spiffe://.*spire-identity-exchange"\]' "${aout}" &&
      ok "agent: the exchange is an authorized delegate" ||
      fail "agent: authorized_delegates not set for the exchange"
  else
    grep -q 'authorized_delegates = \[\]' "${aout}" &&
      ok "agent: no delegates authorized when six is off" ||
      fail "agent: authorized_delegates should be empty with six off"
  fi
done

echo
if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} check(s) failed" >&2
  exit 1
fi
echo "all host config checks passed"
