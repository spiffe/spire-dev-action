#!/usr/bin/env bash
# spire-dev-action entrypoint.
#
# Deploys SPIRE for testing an application against. Runnable directly, not only
# through the composite action: every input arrives as a SPIRE_DEV_* environment
# variable and nothing here depends on GitHub Actions (see scripts/lib/log.sh,
# which is the only file that does).
#
# Usage:
#   SPIRE_DEV_MODE=host  scripts/spire-dev.sh deploy
#   SPIRE_DEV_MODE=k8s   scripts/spire-dev.sh deploy
#                        scripts/spire-dev.sh diagnostics
#                        scripts/spire-dev.sh teardown

set -eo pipefail

SPIRE_DEV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/versions.sh
. "${SPIRE_DEV_SCRIPT_DIR}/lib/versions.sh"

usage() {
  cat >&2 <<'EOF'
usage: spire-dev.sh <deploy|diagnostics|teardown>

Inputs are read from the environment:
  SPIRE_DEV_MODE                     host | k8s                    (required)
  SPIRE_DEV_TRUST_DOMAIN             default example.org
  SPIRE_DEV_ENTRIES                  inline YAML list of entries
  SPIRE_DEV_ENTRIES_FILE             path to a YAML/JSON list of entries
  SPIRE_DEV_MANIFESTS_DIR            dir of ClusterStaticEntry manifests
  SPIRE_DEV_CONTROLLER_MANAGER       true | false | auto
  SPIRE_DEV_OIDC_DISCOVERY_PROVIDER  true | false
  SPIRE_DEV_IDENTITY_EXCHANGE        true | false
  SPIRE_DEV_ALLOW_HOST_MODIFICATION  true | false   (host mode, outside CI)

  host mode:  SPIRE_DEV_INSTANCE, SPIRE_DEV_NODE_ID, SPIRE_DEV_BIND_ADDRESS,
              SPIRE_DEV_BIND_PORT, SPIRE_DEV_SERVER_ADDRESS, SPIRE_DEV_OIDC_PORT
  k8s mode:   SPIRE_DEV_CLUSTER, SPIRE_DEV_CLUSTER_NAME, SPIRE_DEV_K8S_VERSION,
              SPIRE_DEV_NAMESPACE, SPIRE_DEV_RELEASE_NAME, SPIRE_DEV_VALUES

See README.md for the full list and for the entries schema.
EOF
  exit 2
}

# apply_defaults — one place where every input's default lives, so the composite
# action, the self-tests and a direct shell invocation all agree.
apply_defaults() {
  : "${SPIRE_DEV_TRUST_DOMAIN:=example.org}"
  : "${SPIRE_DEV_LOG_LEVEL:=DEBUG}"

  : "${SPIRE_DEV_ENTRIES:=}"
  : "${SPIRE_DEV_ENTRIES_FILE:=}"
  : "${SPIRE_DEV_MANIFESTS_DIR:=}"
  : "${SPIRE_DEV_CONTROLLER_MANAGER:=auto}"
  : "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER:=}"
  : "${SPIRE_DEV_IDENTITY_EXCHANGE:=false}"
  : "${SPIRE_DEV_ALLOW_HOST_MODIFICATION:=false}"
  : "${SPIRE_DEV_WORKLOAD_ATTESTORS:=}"
  : "${SPIRE_DEV_AGENT_EXTRA_PLUGINS:=}"

  # host mode
  : "${SPIRE_DEV_INSTANCE:=main}"
  : "${SPIRE_DEV_NODE_ID:=node1}"
  : "${SPIRE_DEV_BIND_ADDRESS:=0.0.0.0}"
  : "${SPIRE_DEV_BIND_PORT:=8081}"
  : "${SPIRE_DEV_SERVER_ADDRESS:=localhost}"
  : "${SPIRE_DEV_OIDC_PORT:=8181}"
  : "${SPIRE_DEV_CONTROLLER_MANAGER_METRICS_ADDRESS:=127.0.0.1:9123}"
  : "${SPIRE_DEV_CONTROLLER_MANAGER_HEALTH_ADDRESS:=127.0.0.1:9124}"

  # spire-identity-exchange, host mode. Ports match the package defaults so that
  # anything written against the exchange's own documentation still applies.
  : "${SPIRE_DEV_IDENTITY_EXCHANGE_CONFIG:=}"
  : "${SPIRE_DEV_SIX_LOG_LEVEL:=info}"
  : "${SPIRE_DEV_SIX_PURPOSE_MODE:=shared}"
  : "${SPIRE_DEV_SIX_METRICS_PORT:=4950}"
  : "${SPIRE_DEV_SIX_SVID_TTL:=1h}"
  : "${SPIRE_DEV_SIX_TLS_GRPC_PORT:=8443}"
  : "${SPIRE_DEV_SIX_TLS_REST_PORT:=8444}"
  : "${SPIRE_DEV_SIX_SPIFFE_GRPC_PORT:=8543}"
  : "${SPIRE_DEV_SIX_SPIFFE_REST_PORT:=8544}"

  # k8s mode
  : "${SPIRE_DEV_CLUSTER:=existing}"
  : "${SPIRE_DEV_CLUSTER_NAME:=spire-dev}"
  : "${SPIRE_DEV_NAMESPACE:=spire-server}"
  : "${SPIRE_DEV_RELEASE_NAME:=spire}"
  : "${SPIRE_DEV_VALUES:=}"

  export SPIRE_DEV_TRUST_DOMAIN SPIRE_DEV_LOG_LEVEL SPIRE_DEV_ENTRIES \
    SPIRE_DEV_ENTRIES_FILE SPIRE_DEV_MANIFESTS_DIR SPIRE_DEV_CONTROLLER_MANAGER \
    SPIRE_DEV_OIDC_DISCOVERY_PROVIDER SPIRE_DEV_IDENTITY_EXCHANGE \
    SPIRE_DEV_ALLOW_HOST_MODIFICATION SPIRE_DEV_WORKLOAD_ATTESTORS \
    SPIRE_DEV_AGENT_EXTRA_PLUGINS SPIRE_DEV_INSTANCE SPIRE_DEV_NODE_ID \
    SPIRE_DEV_BIND_ADDRESS SPIRE_DEV_BIND_PORT SPIRE_DEV_SERVER_ADDRESS \
    SPIRE_DEV_OIDC_PORT SPIRE_DEV_CONTROLLER_MANAGER_METRICS_ADDRESS \
    SPIRE_DEV_CONTROLLER_MANAGER_HEALTH_ADDRESS SPIRE_DEV_CLUSTER \
    SPIRE_DEV_CLUSTER_NAME SPIRE_DEV_NAMESPACE \
    SPIRE_DEV_RELEASE_NAME SPIRE_DEV_VALUES \
    SPIRE_DEV_IDENTITY_EXCHANGE_CONFIG SPIRE_DEV_SIX_LOG_LEVEL \
    SPIRE_DEV_SIX_PURPOSE_MODE SPIRE_DEV_SIX_METRICS_PORT SPIRE_DEV_SIX_SVID_TTL \
    SPIRE_DEV_SIX_TLS_GRPC_PORT SPIRE_DEV_SIX_TLS_REST_PORT \
    SPIRE_DEV_SIX_SPIFFE_GRPC_PORT SPIRE_DEV_SIX_SPIFFE_REST_PORT
}

# AGENT_WORKLOAD_ATTESTOR_ALLOWLIST — the workload attestors that can be named in
# the workload-attestors input.
#
# Deliberately restricted to attestors that need no plugin_data, because that is
# all a bare name can express. It is an allowlist rather than a passthrough so a
# typo fails here: SPIRE will not start on an unknown plugin name, but "slrum"
# silently spelled as an unchecked passthrough would instead produce an agent that
# starts cleanly and then never matches the workload -- the exact class of
# failure this action exists to make impossible. Anything needing configuration
# goes through agent-extra-plugins.
AGENT_WORKLOAD_ATTESTOR_ALLOWLIST="docker slurm systemd unix"

# validate_agent_plugins — check the agent plugin inputs.
validate_agent_plugins() {
  if [ "${SPIRE_DEV_MODE}" = "k8s" ]; then
    if [ -n "${SPIRE_DEV_WORKLOAD_ATTESTORS}" ]; then
      log_fail "workload-attestors is host mode only; in k8s mode set the agent's" \
        "workloadAttestors through the values input"
    fi
    if [ -n "${SPIRE_DEV_AGENT_EXTRA_PLUGINS}" ]; then
      log_fail "agent-extra-plugins is host mode only; in k8s mode configure the" \
        "agent through the values input"
    fi
    return 0
  fi

  local name
  while IFS= read -r name; do
    case " ${AGENT_WORKLOAD_ATTESTOR_ALLOWLIST} " in
    *" ${name} "*) ;;
    *)
      log_fail "workload-attestors: '${name}' is not a known no-configuration" \
        "attestor (${AGENT_WORKLOAD_ATTESTOR_ALLOWLIST}); an attestor needing" \
        "plugin_data goes in agent-extra-plugins instead"
      ;;
    esac
  done < <(split_list "${SPIRE_DEV_WORKLOAD_ATTESTORS}")
}

# validate_inputs — reject contradictions up front, so a caller sees the problem
# with their workflow rather than a failure from a tool three steps later.
validate_inputs() {
  case "${SPIRE_DEV_MODE:-}" in
  host | k8s) ;;
  "") log_fail "mode is required: host or k8s" ;;
  *) log_fail "mode must be host or k8s; got '${SPIRE_DEV_MODE}'" ;;
  esac

  # The default differs by mode. In k8s the chart enables it anyway and its helm
  # test uses it as a workload check, so it is worth having; on a host it needs a
  # unit this action supplies and serves no purpose unless something outside
  # SPIRE has to verify a JWT-SVID.
  if [ -z "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER}" ]; then
    if [ "${SPIRE_DEV_MODE}" = "k8s" ]; then
      SPIRE_DEV_OIDC_DISCOVERY_PROVIDER=true
    else
      SPIRE_DEV_OIDC_DISCOVERY_PROVIDER=false
    fi
    export SPIRE_DEV_OIDC_DISCOVERY_PROVIDER
  fi

  case "${SPIRE_DEV_CLUSTER}" in
  existing | kind) ;;
  *) log_fail "cluster must be existing or kind; got '${SPIRE_DEV_CLUSTER}'" ;;
  esac

  # A trust domain that is not a valid DNS-ish name produces confusing failures
  # deep inside SPIRE, so it is checked here.
  if ! printf '%s' "${SPIRE_DEV_TRUST_DOMAIN}" |
    grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
    log_fail "trust-domain '${SPIRE_DEV_TRUST_DOMAIN}' is not a valid trust domain name"
  fi

  validate_agent_plugins

  if [ -n "${SPIRE_DEV_ENTRIES_FILE}" ] && [ ! -f "${SPIRE_DEV_ENTRIES_FILE}" ]; then
    log_fail "entries-file does not exist: ${SPIRE_DEV_ENTRIES_FILE}"
  fi
  if [ -n "${SPIRE_DEV_MANIFESTS_DIR}" ] && [ ! -d "${SPIRE_DEV_MANIFESTS_DIR}" ]; then
    log_fail "manifests-dir does not exist: ${SPIRE_DEV_MANIFESTS_DIR}"
  fi
}

main() {
  local command="${1:-}"
  [ -n "${command}" ] || usage

  apply_defaults
  load_versions
  validate_inputs

  log_info "spire-dev-action: ${command} (mode=${SPIRE_DEV_MODE}, trust domain=${SPIRE_DEV_TRUST_DOMAIN})"
  log_info "work dir: ${SPIRE_DEV_WORK_DIR}"
  print_versions

  case "${command}" in
  deploy)
    case "${SPIRE_DEV_MODE}" in
    host)
      # shellcheck source=./host/deploy.sh
      . "${SPIRE_DEV_SCRIPT_DIR}/host/deploy.sh"
      host_deploy
      ;;
    k8s)
      # shellcheck source=./k8s/deploy.sh
      . "${SPIRE_DEV_SCRIPT_DIR}/k8s/deploy.sh"
      k8s_deploy
      ;;
    esac
    ;;
  diagnostics)
    # shellcheck source=./lib/diag.sh
    . "${SPIRE_DEV_SCRIPT_DIR}/lib/diag.sh"
    diag_collect
    ;;
  teardown)
    case "${SPIRE_DEV_MODE}" in
    host)
      # shellcheck source=./host/teardown.sh
      . "${SPIRE_DEV_SCRIPT_DIR}/host/teardown.sh"
      host_teardown
      ;;
    k8s)
      # shellcheck source=./k8s/teardown.sh
      . "${SPIRE_DEV_SCRIPT_DIR}/k8s/teardown.sh"
      k8s_teardown
      ;;
    esac
    ;;
  *)
    log_error "unknown command: ${command}"
    usage
    ;;
  esac
}

main "$@"
