#!/usr/bin/env bash
# Golden-file tests for scripts/lib/entries.sh.
#
# Pure text transformation, so this needs no cluster, no root and no SPIRE, and
# is safe to run anywhere. Regenerate the golden files after an intentional
# change with:  tests/entries/run-tests.sh --update

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT}/../.." && pwd)"

# shellcheck source=../../scripts/lib/entries.sh
. "${ROOT}/scripts/lib/entries.sh"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

TRUST_DOMAIN="example.test"
DEFAULT_PARENT="spiffe://${TRUST_DOMAIN}/agent/node1"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0

# check <name> <actual-file> — diff against tests/entries/golden/<name>.
check() {
  local name="$1"
  local actual="$2"
  local golden="${SCRIPT}/golden/${name}"

  mkdir -p "$(dirname "${golden}")"
  if [ "${UPDATE}" -eq 1 ]; then
    cp "${actual}" "${golden}"
    echo "updated ${name}"
    return 0
  fi

  if [ ! -f "${golden}" ]; then
    echo "FAIL ${name}: no golden file; run with --update to create it" >&2
    FAILURES=$((FAILURES + 1))
    return 0
  fi

  if diff -u "${golden}" "${actual}" >"${WORK}/diff"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}" >&2
    sed 's/^/    /' "${WORK}/diff" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# expect_error <name> <entries-yaml> <expected-substring>
expect_error() {
  local name="$1"
  local yaml="$2"
  local expect="$3"
  local input="${WORK}/${name}.yaml"
  printf '%s\n' "${yaml}" >"${input}"

  local output rc=0
  output="$(entries_normalize "${input}" "${TRUST_DOMAIN}" "${DEFAULT_PARENT}" 2>&1)" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "FAIL ${name}: expected failure, got success" >&2
    FAILURES=$((FAILURES + 1))
  elif ! printf '%s' "${output}" | grep -qF "${expect}"; then
    echo "FAIL ${name}: error did not mention '${expect}'" >&2
    printf '%s\n' "${output}" | sed 's/^/    /' >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   ${name} (rejected: ${expect})"
  fi
}

echo "== rendering golden files"
for input in "${SCRIPT}"/input/*.yaml; do
  case_name="$(basename "${input}" .yaml)"

  # Emitters 1 and 3 use the real trust domain.
  canonical="$(entries_normalize "${input}" "${TRUST_DOMAIN}" "${DEFAULT_PARENT}")"
  printf '%s\n' "${canonical}" | jq '.' >"${WORK}/canonical.json"
  check "${case_name}/canonical.json" "${WORK}/canonical.json"

  entries_to_server_json "${canonical}" "${WORK}/server.json"
  check "${case_name}/server.json" "${WORK}/server.json"

  # The helm chart accepts a strict subset of the CRD's fields, so some cases
  # are expected to be rejected by that emitter alone.
  case "${case_name}" in
  store-svid)
    if (entries_to_helm_values "${canonical}" "${WORK}/helm-values.yaml") 2>"${WORK}/helm.err"; then
      echo "FAIL ${case_name}: helm emitter accepted a field the chart rejects" >&2
      FAILURES=$((FAILURES + 1))
    elif grep -qF "storeSVID" "${WORK}/helm.err"; then
      echo "ok   ${case_name}/helm-values.yaml (rejected: storeSVID)"
    else
      echo "FAIL ${case_name}: helm emitter failed without naming storeSVID" >&2
      sed 's/^/    /' "${WORK}/helm.err" >&2
      FAILURES=$((FAILURES + 1))
    fi
    ;;
  *)
    entries_to_helm_values "${canonical}" "${WORK}/helm-values.yaml"
    check "${case_name}/helm-values.yaml" "${WORK}/helm-values.yaml"
    ;;
  esac

  # Emitter 2 leaves the trust domain as a placeholder for the
  # controller-manager to expand.
  placeholder_canonical="$(entries_normalize "${input}" \
    "${ENTRIES_TRUST_DOMAIN_PLACEHOLDER}" \
    "spiffe://${ENTRIES_TRUST_DOMAIN_PLACEHOLDER}/agent/node1")"
  rm -rf "${WORK}/manifests"
  entries_to_static_manifests "${placeholder_canonical}" "${WORK}/manifests"
  for manifest in "${WORK}/manifests"/*.yaml; do
    check "${case_name}/manifests/$(basename "${manifest}")" "${manifest}"
  done
done

echo
echo "== generated helm values render against the real chart"
# This is the check that catches the emitter drifting from what the chart's
# clusterStaticEntries values actually accept; the chart hard-fails on an
# unsupported key. Skipped when helm or the chart repo is unreachable, so the
# rest of the suite stays runnable offline.
if ! command -v helm >/dev/null 2>&1; then
  echo "skip helm render (helm not installed)"
else
  chart_args=(spire --repo "${SPIRE_DEV_CHARTS_REPO:-https://spiffe.github.io/helm-charts-hardened/}")
  [ -n "${SPIRE_DEV_CHARTS_SPIRE:-}" ] && chart_args+=(--version "${SPIRE_DEV_CHARTS_SPIRE}")
  for values in "${SCRIPT}"/golden/*/helm-values.yaml; do
    [ -f "${values}" ] || continue
    case_name="$(basename "$(dirname "${values}")")"
    if ! helm template render-check "${chart_args[@]}" -f "${values}" \
      >"${WORK}/render.yaml" 2>"${WORK}/render.err"; then
      if grep -qiE 'could not find|no cached repo|dial tcp|timeout|connection refused' "${WORK}/render.err"; then
        echo "skip helm render for ${case_name} (chart repo unreachable)"
        continue
      fi
      echo "FAIL helm render for ${case_name}" >&2
      sed 's/^/    /' "${WORK}/render.err" >&2
      FAILURES=$((FAILURES + 1))
      continue
    fi
    # Every entry we asked for must actually appear as a ClusterStaticEntry. The
    # chart prefixes the object name with <namespace>-<release>- so that parallel
    # installs do not collide, so match on the suffix.
    yq 'select(.kind == "ClusterStaticEntry") | .metadata.name' "${WORK}/render.yaml" \
      >"${WORK}/rendered-names.txt"
    case_failed=0
    expected="$(yq -o=json -I=0 '[.["spire-server"].controllerManager.identities.clusterStaticEntries | keys | .[]]' "${values}")"
    for name in $(printf '%s' "${expected}" | jq -r '.[]'); do
      if ! grep -qE "(^|-)${name}\$" "${WORK}/rendered-names.txt"; then
        echo "FAIL helm render for ${case_name}: no ClusterStaticEntry named ${name}" >&2
        echo "    rendered: $(tr '\n' ' ' <"${WORK}/rendered-names.txt")" >&2
        FAILURES=$((FAILURES + 1))
        case_failed=1
      fi
    done
    [ "${case_failed}" -eq 0 ] && echo "ok   helm render for ${case_name}"
  done
fi

echo
echo "== combining inline and file inputs"
printf '%s\n' "- spiffeID: from-file
  selectors: [systemd:id:from-file.service]" >"${WORK}/from-file.yaml"
entries_collect "- spiffeID: inline
  selectors: [systemd:id:inline.service]" "${WORK}/from-file.yaml" "${WORK}/combined.yaml"
entries_normalize "${WORK}/combined.yaml" "${TRUST_DOMAIN}" "${DEFAULT_PARENT}" |
  jq -r '.[].spiffeID' >"${WORK}/combined-ids.txt"
check "combined-ids.txt" "${WORK}/combined-ids.txt"

echo
echo "== empty input is not an error"
: >"${WORK}/empty.yaml"
entries_collect "" "" "${WORK}/empty-combined.yaml"
result="$(entries_normalize "${WORK}/empty-combined.yaml" "${TRUST_DOMAIN}" "${DEFAULT_PARENT}")"
if [ "$(printf '%s' "${result}" | jq 'length')" -eq 0 ]; then
  echo "ok   empty input yields no entries"
else
  echo "FAIL empty input yielded: ${result}" >&2
  FAILURES=$((FAILURES + 1))
fi

echo
echo "== invalid input is rejected with a useful message"
expect_error "missing-spiffeid" \
  "- selectors: [systemd:id:x.service]" \
  "missing spiffeID"
expect_error "no-selectors" \
  "- spiffeID: myapp" \
  "has no selectors"
expect_error "bad-selector" \
  "- spiffeID: myapp
  selectors: [notatypevalue]" \
  "is not in type:value form"
expect_error "not-a-list" \
  "spiffeID: myapp" \
  "entries must be a list"
expect_error "entry-not-a-mapping" \
  "- just-a-string" \
  "must be a mapping"

echo
if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} check(s) failed" >&2
  exit 1
fi
echo "all entry renderer checks passed"
