#!/usr/bin/env bash
# Renders the values k8s mode composes against the real spire chart.
#
# No cluster and no root: this only calls `helm template`, so it catches the whole
# class of bug where the values this action generates are not what the chart
# accepts. It is the local check that a k8s-mode change did not break the install
# before a runner spends minutes on a kind cluster.
#
# Skipped rather than failed when helm is missing or the chart repo is unreachable,
# so it stays runnable offline.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT}/../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export SPIRE_DEV_WORK_DIR="${WORK}/work"

# shellcheck source=../../scripts/lib/versions.sh
. "${ROOT}/scripts/lib/versions.sh"
load_versions
# shellcheck source=../../scripts/k8s/deploy.sh
. "${ROOT}/scripts/k8s/deploy.sh"

FAILURES=0

if ! command -v helm >/dev/null 2>&1; then
  echo "skip: helm is not installed"
  exit 0
fi

# render <case-name> — compose the values the way k8s_install_charts does and
# render them. Echoes the rendered manifest path.
render() {
  local case_name="$1"
  local -a value_args=()

  local base entries user_args
  base="$(k8s_write_base_values)"
  value_args+=(--values "${base}")

  # Mirrors k8s_install_charts: the exchange values come from six.sh, but the TLS
  # secret it also creates needs a cluster, so only the values part runs here.
  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE}"; then
    # shellcheck source=../../scripts/k8s/six.sh
    . "${ROOT}/scripts/k8s/six.sh"
    value_args+=(--values "$(k8s_six_write_values)")
  fi

  entries="$(k8s_write_entries_values)"
  if [ -n "${entries}" ]; then
    value_args+=(--values "${entries}")
  fi

  user_args="$(work_dir)/user-value-args"
  k8s_user_value_args >"${user_args}"
  local arg_line
  while IFS= read -r arg_line; do
    [ -n "${arg_line}" ] && value_args+=("${arg_line}")
  done <"${user_args}"

  if ! helm template "${SPIRE_DEV_RELEASE_NAME}" spire \
    --repo "${SPIRE_DEV_CHARTS_REPO}" --version "${SPIRE_DEV_CHARTS_SPIRE}" \
    -n "${SPIRE_DEV_NAMESPACE}" \
    "${value_args[@]}" >"${WORK}/${case_name}.yaml" 2>"${WORK}/${case_name}.err"; then
    if grep -qiE 'could not find|no cached repo|dial tcp|timeout|connection refused' "${WORK}/${case_name}.err"; then
      echo "skip ${case_name}: chart repo unreachable"
      return 1
    fi
    echo "FAIL ${case_name}: helm template failed" >&2
    sed 's/^/    /' "${WORK}/${case_name}.err" >&2
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  return 0
}

# assert_present <case> <file> <description> <yq-expression>
assert_present() {
  local case_name="$1" file="$2" description="$3" expr="$4"
  local got
  got="$(yq "${expr}" "${file}" 2>/dev/null | grep -v '^null$' | grep -c . || true)"
  if [ "${got}" -gt 0 ]; then
    echo "ok   ${case_name}: ${description}"
  else
    echo "FAIL ${case_name}: ${description}" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_absent <case> <file> <description> <yq-expression>
assert_absent() {
  local case_name="$1" file="$2" description="$3" expr="$4"
  local got
  got="$(yq "${expr}" "${file}" 2>/dev/null | grep -v '^null$' | grep -c . || true)"
  if [ "${got}" -eq 0 ]; then
    echo "ok   ${case_name}: ${description}"
  else
    echo "FAIL ${case_name}: ${description} (found ${got})" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_equals <case> <description> <expected> <actual>
assert_equals() {
  local case_name="$1" description="$2" expected="$3" actual="$4"
  if [ "${expected}" = "${actual}" ]; then
    echo "ok   ${case_name}: ${description}"
  else
    echo "FAIL ${case_name}: ${description}" >&2
    echo "     expected: ${expected}" >&2
    echo "     actual:   ${actual}" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# reset_inputs — start each case from the documented defaults.
reset_inputs() {
  rm -rf "${SPIRE_DEV_WORK_DIR}"
  SPIRE_DEV_TRUST_DOMAIN="test.example"
  SPIRE_DEV_CLUSTER_NAME="test-cluster"
  SPIRE_DEV_NAMESPACE="spire-server"
  SPIRE_DEV_RELEASE_NAME="spire"
  SPIRE_DEV_ENTRIES=""
  SPIRE_DEV_ENTRIES_FILE=""
  SPIRE_DEV_MANIFESTS_DIR=""
  SPIRE_DEV_CONTROLLER_MANAGER="auto"
  SPIRE_DEV_OIDC_DISCOVERY_PROVIDER="true"
  SPIRE_DEV_IDENTITY_EXCHANGE="false"
  SPIRE_DEV_VALUES=""
  export SPIRE_DEV_TRUST_DOMAIN SPIRE_DEV_CLUSTER_NAME SPIRE_DEV_NAMESPACE \
    SPIRE_DEV_RELEASE_NAME SPIRE_DEV_ENTRIES SPIRE_DEV_ENTRIES_FILE \
    SPIRE_DEV_MANIFESTS_DIR SPIRE_DEV_CONTROLLER_MANAGER \
    SPIRE_DEV_OIDC_DISCOVERY_PROVIDER SPIRE_DEV_IDENTITY_EXCHANGE SPIRE_DEV_VALUES
  k8s_resolve_controller_manager >/dev/null
}

echo "== defaults"
reset_inputs
if render defaults; then
  f="${WORK}/defaults.yaml"
  assert_present defaults "${f}" "the server is rendered" \
    'select(.kind == "StatefulSet") | .metadata.name'
  assert_present defaults "${f}" "the agent is rendered" \
    'select(.kind == "DaemonSet" and (.metadata.name | test("agent"))) | .metadata.name'
  assert_present defaults "${f}" "the CSI driver is rendered" \
    'select(.kind == "CSIDriver") | .metadata.name'
  assert_present defaults "${f}" "the OIDC provider is rendered" \
    'select(.kind == "Deployment" and (.metadata.name | test("oidc"))) | .metadata.name'
  # The trust domain must actually reach the server config, not just the values.
  if grep -q 'test.example' "${f}"; then
    echo "ok   defaults: the trust domain reached the manifests"
  else
    echo "FAIL defaults: the trust domain did not reach the manifests" >&2
    FAILURES=$((FAILURES + 1))
  fi
  # The default trust domain leaking through would mean an override was missed.
  if grep -q 'example\.org' "${f}"; then
    echo "FAIL defaults: example.org appears in the manifests; an override was missed" >&2
    grep -n 'example\.org' "${f}" | head -5 >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   defaults: no leftover example.org"
  fi
fi

echo
echo "== entries become ClusterStaticEntry objects"
reset_inputs
SPIRE_DEV_ENTRIES="- spiffeID: myapp
  selectors: [k8s:ns:default]"
export SPIRE_DEV_ENTRIES
if render entries; then
  f="${WORK}/entries.yaml"
  assert_present entries "${f}" "myapp is a ClusterStaticEntry" \
    'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("myapp"))) | .metadata.name'

  # A workload entry has to parent on an agent, and under k8s_psat there is no fixed
  # agent ID to name, so the action creates a node alias and parents entries on it.
  # Getting this wrong is invisible at render time and only shows up as
  # "no identity issued" when a workload asks for an SVID, so it is pinned here.
  assert_present entries "${f}" "the node alias is rendered" \
    'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("spire-dev-action-agents"))) | .metadata.name'
  assert_equals entries "the alias selects every agent in the cluster" \
    "k8s_psat:cluster:test-cluster" \
    "$(yq 'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("spire-dev-action-agents"))) | .spec.selectors[0]' "${f}")"
  assert_equals entries "the alias parents on the server" \
    "spiffe://test.example/spire/server" \
    "$(yq 'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("spire-dev-action-agents"))) | .spec.parentID' "${f}")"
  assert_equals entries "myapp parents on the alias, not the server" \
    "spiffe://test.example/spire-dev-action/agents" \
    "$(yq 'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("myapp"))) | .spec.parentID' "${f}")"
fi

echo
echo "== no entries means no node alias"
reset_inputs
if render no-entries; then
  assert_absent no-entries "${WORK}/no-entries.yaml" "no node alias is rendered" \
    'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("spire-dev-action-agents"))) | .metadata.name'
fi

echo
echo "== the OIDC provider can be disabled"
reset_inputs
SPIRE_DEV_OIDC_DISCOVERY_PROVIDER="false"
export SPIRE_DEV_OIDC_DISCOVERY_PROVIDER
if render no-oidc; then
  assert_absent no-oidc "${WORK}/no-oidc.yaml" "no OIDC deployment is rendered" \
    'select(.kind == "Deployment" and (.metadata.name | test("oidc"))) | .metadata.name'
  assert_present no-oidc "${WORK}/no-oidc.yaml" "the server is still rendered" \
    'select(.kind == "StatefulSet") | .metadata.name'
fi

echo
echo "== the controller-manager can be disabled"
reset_inputs
SPIRE_DEV_CONTROLLER_MANAGER="false"
export SPIRE_DEV_CONTROLLER_MANAGER
k8s_resolve_controller_manager >/dev/null
if render no-cm; then
  assert_absent no-cm "${WORK}/no-cm.yaml" "no ClusterSPIFFEID objects are rendered" \
    'select(.kind == "ClusterSPIFFEID") | .metadata.name'
  assert_present no-cm "${WORK}/no-cm.yaml" "the server is still rendered" \
    'select(.kind == "StatefulSet") | .metadata.name'
fi

echo
echo "== identity-exchange can be enabled"
reset_inputs
SPIRE_DEV_IDENTITY_EXCHANGE="true"
export SPIRE_DEV_IDENTITY_EXCHANGE
if render six; then
  assert_present six "${WORK}/six.yaml" "the exchange is rendered" \
    'select(.kind == "Deployment" and (.metadata.name | test("identity-exchange"))) | .metadata.name'
  assert_present six "${WORK}/six.yaml" "the REST service is rendered" \
    'select(.kind == "Service" and (.metadata.name | test("identity-exchange-rest"))) | .metadata.name'
  # Proves the workaround for the chart's grpc-service.yaml nil-pointer bug holds.
  assert_present six "${WORK}/six.yaml" "the gRPC service is rendered" \
    'select(.kind == "Service" and (.metadata.name | test("identity-exchange-grpc"))) | .metadata.name'
  assert_present six "${WORK}/six.yaml" "the TLS secret is referenced" \
    'select(.kind == "Deployment") | .spec.template.spec.volumes[]? | select(.secret.secretName? == "spire-identity-exchange-tls") | .name'
fi

echo
echo "== entries and identity-exchange together do not conflict"
reset_inputs
SPIRE_DEV_IDENTITY_EXCHANGE="true"
SPIRE_DEV_ENTRIES="- spiffeID: myapp
  selectors: [k8s:ns:default]"
export SPIRE_DEV_IDENTITY_EXCHANGE SPIRE_DEV_ENTRIES
if render six-and-entries; then
  assert_present six-and-entries "${WORK}/six-and-entries.yaml" "the entry survived" \
    'select(.kind == "ClusterStaticEntry" and (.metadata.name | test("myapp"))) | .metadata.name'
  assert_present six-and-entries "${WORK}/six-and-entries.yaml" "the exchange survived" \
    'select(.kind == "Deployment" and (.metadata.name | test("identity-exchange"))) | .metadata.name'
fi

echo
echo "== user values are applied last and override ours"
reset_inputs
SPIRE_DEV_VALUES='global:
  spire:
    clusterName: overridden-by-user'
export SPIRE_DEV_VALUES
if render user-values; then
  if grep -q 'overridden-by-user' "${WORK}/user-values.yaml"; then
    echo "ok   user-values: the caller's value won"
  else
    echo "FAIL user-values: the caller's value was not applied" >&2
    FAILURES=$((FAILURES + 1))
  fi
fi

echo
echo "== a values path that does not exist is rejected"
reset_inputs
SPIRE_DEV_VALUES="/nonexistent/values.yaml"
export SPIRE_DEV_VALUES
if (k8s_user_value_args >/dev/null) 2>"${WORK}/bad-values.err"; then
  echo "FAIL bad-values: a nonexistent path was accepted" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "ok   bad-values: rejected"
fi

echo
if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} check(s) failed" >&2
  exit 1
fi
echo "all k8s values checks passed"
