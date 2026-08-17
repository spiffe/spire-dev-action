#!/usr/bin/env bash
# Optional: spire-identity-exchange on the host.
#
# This is the most involved component in host mode. spire-identity-exchange needs,
# beyond its own binary:
#
#   * a CredentialComposer plugin on the server, which sets the CN on issued
#     X509-SVIDs so the exchange can be identified by an x509pop selector;
#   * a spiffe-workload-api server attestor, which the second agent rebootstraps
#     through;
#   * a second agent instance whose delegated identity API is authorized for the
#     exchange and nothing else;
#   * bootstrap registration entries for the exchange itself and for the second
#     agent, which have to exist before either can attest.
#
# The wiring follows spire-identity-exchange's own integration tests
# (tests/integration/common/{common.sh,server.conf,six-agent.conf} and
# tests/integration/common/manifests/) rather than being derived independently,
# because the x509pop mode, the SPIFFE path prefixes and the selectors all have to
# agree exactly for attestation to succeed.
#
# Unlike the reference, which builds the plugin and attestor from source, these are
# installed from the same package feed as everything else.

[ -n "${_SPIRE_DEV_HOST_SIX_SH:-}" ] && return 0
_SPIRE_DEV_HOST_SIX_SH=1

_host_six_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./configure.sh
. "${_host_six_dir}/configure.sh"
# shellcheck source=../lib/wait.sh
. "${_host_six_dir}/../lib/wait.sh"
# shellcheck source=../lib/entries.sh
. "${_host_six_dir}/../lib/entries.sh"

# host_deploy_six <instance> <agent-spiffe-id>
host_deploy_six() {
  local instance="$1"
  local agent_id="$2"

  log_group "Deploying spire-identity-exchange"

  _six_assert_installed
  _six_generate_cert "${instance}"
  _six_write_config "${instance}"
  _six_start_server_attestor "${instance}"
  _six_create_bootstrap_entries "${instance}" "${agent_id}"
  _six_start_second_agent "${instance}"
  _six_start_exchange "${instance}"

  log_set_output identity-exchange-grpc-url "https://localhost:${SPIRE_DEV_SIX_TLS_GRPC_PORT}"
  log_set_output identity-exchange-rest-url "https://localhost:${SPIRE_DEV_SIX_TLS_REST_PORT}"
  log_set_output identity-exchange-ca-file \
    "$(identity_exchange_cert_dir "${instance}")/server.pem"

  log_endgroup
}

# _six_assert_installed — check for the pieces before touching anything, so a
# missing package produces one clear message rather than a failure part way
# through.
_six_assert_installed() {
  local missing=()

  # The rpm packaging installs the exchange to /usr/bin while its unit runs
  # /usr/libexec/spire/. A symlink is created rather than failing, because which
  # of the two the deb uses is a packaging detail that has changed before.
  if [ ! -x /usr/libexec/spire/spire-identity-exchange-server ]; then
    if [ -x /usr/bin/spire-identity-exchange-server ]; then
      log_info "linking /usr/bin/spire-identity-exchange-server into /usr/libexec/spire/, where the unit expects it"
      sudo mkdir -p /usr/libexec/spire
      sudo ln -sf /usr/bin/spire-identity-exchange-server \
        /usr/libexec/spire/spire-identity-exchange-server
    else
      missing+=("spire-identity-exchange-server")
    fi
  fi

  [ -x /usr/libexec/spire/plugins/credentialcomposer-identity-exchange ] ||
    missing+=("credentialcomposer-identity-exchange (package spire-credentialcomposer-identity-exchange)")
  [ -x /usr/libexec/spire/spire-server-attestor-spiffe-workload-api ] ||
    missing+=("spire-server-attestor-spiffe-workload-api")
  [ -f /usr/lib/systemd/system/spire-identity-exchange-server@.service ] ||
    missing+=("the spire-identity-exchange-server@.service unit")

  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "spire-identity-exchange cannot be deployed; these are missing after package installation:"
    local item
    for item in "${missing[@]}"; do
      log_error "  - ${item}"
    done
    log_fail "identity-exchange requires these from the spire-examples package feed. Set identity-exchange: false, or use mode: k8s where the chart provides them."
  fi
}

# _six_generate_cert <instance> — self-signed certificate for the TLS listeners.
#
# Used directly as the CA by clients (it is its own issuer), which is why CA:TRUE
# is set. The SANs have to cover every name a caller might connect by, since an
# X509 client verifies the hostname.
_six_generate_cert() {
  local instance="$1"
  local cert_dir
  cert_dir="$(identity_exchange_cert_dir "${instance}")"

  if sudo test -f "${cert_dir}/server.pem"; then
    log_info "reusing the existing certificate in ${cert_dir}"
    return 0
  fi

  require_cmd openssl
  sudo mkdir -p "${cert_dir}"

  local trust_domain="${SPIRE_DEV_TRUST_DOMAIN}"
  sudo openssl req -x509 -newkey rsa:2048 \
    -keyout "${cert_dir}/server.key" \
    -out "${cert_dir}/server.pem" \
    -sha256 -days 365 -nodes \
    -subj "/CN=localhost" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "subjectAltName=DNS:localhost,DNS:spire-identity-exchange.${trust_domain},DNS:spire-identity-exchange-rest.${trust_domain},IP:127.0.0.1" \
    2>/dev/null || log_fail "could not generate the identity-exchange certificate"

  log_info "generated a self-signed certificate in ${cert_dir}"
}

_six_write_config() {
  local instance="$1"

  # The unit reads /etc/spire/identity-exchange/<instance>/env, so per-instance
  # settings go there and the package's default.env stays untouched.
  write_root_file "$(identity_exchange_dir "${instance}")/env" <<EOF
SIX_LOG_LEVEL=${SPIRE_DEV_SIX_LOG_LEVEL}
SIX_PURPOSE_MODE=${SPIRE_DEV_SIX_PURPOSE_MODE}
SIX_METRICS_PORT=${SPIRE_DEV_SIX_METRICS_PORT}
SIX_SVID_TTL=${SPIRE_DEV_SIX_SVID_TTL}
SIX_TLS_GRPC_PORT=${SPIRE_DEV_SIX_TLS_GRPC_PORT}
SIX_TLS_REST_PORT=${SPIRE_DEV_SIX_TLS_REST_PORT}
SIX_SPIFFE_GRPC_PORT=${SPIRE_DEV_SIX_SPIFFE_GRPC_PORT}
SIX_SPIFFE_REST_PORT=${SPIRE_DEV_SIX_SPIFFE_REST_PORT}
SIX_GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-unset/unset}
EOF

  # The unit looks for <instance>.json and otherwise falls back to default.conf.
  # The extension is only how the unit finds the file: it is copied to
  # .../<instance>/config before being parsed, so the content is YAML either way,
  # exactly as the package's own default.conf is.
  local source_config="${SPIRE_DEV_ROOT}/conf/host/identity-exchange.conf"
  if [ -n "${SPIRE_DEV_IDENTITY_EXCHANGE_CONFIG:-}" ]; then
    [ -f "${SPIRE_DEV_IDENTITY_EXCHANGE_CONFIG}" ] ||
      log_fail "identity-exchange-config does not exist: ${SPIRE_DEV_IDENTITY_EXCHANGE_CONFIG}"
    source_config="${SPIRE_DEV_IDENTITY_EXCHANGE_CONFIG}"
    log_info "using the supplied identity-exchange config: ${source_config}"
  fi
  write_root_file "/etc/spire/identity-exchange/${instance}.json" <"${source_config}"
}

# _six_start_server_attestor <instance> — the socket the second agent
# rebootstraps through.
_six_start_server_attestor() {
  local instance="$1"
  local unit="spire-server-attestor-spiffe-workload-api@${instance}"

  if [ ! -f "/usr/lib/systemd/system/${unit%@*}@.service" ] &&
    [ ! -f "/etc/systemd/system/${unit%@*}@.service" ]; then
    log_fail "the ${unit%@*}@.service unit is not installed; the spire-server-attestor-spiffe-workload-api package did not install as expected"
  fi

  sudo systemctl daemon-reload
  sudo systemctl restart "${unit}" ||
    log_fail "could not start ${unit}"
  wait_for_systemd_unit "${unit}" ||
    log_fail "${unit} did not become active"
  log_info "started ${unit}"
}

# _six_create_bootstrap_entries <instance> <agent-spiffe-id>
#
# Three entries have to exist before the exchange can work, and they are created
# here rather than being left to the caller because none of them describe the
# caller's application:
#
#   1. the second agent's own workload entry on the primary agent, so it can get
#      the SVID it attests with;
#   2. a node alias for the exchange, matched by the x509pop selector the
#      CredentialComposer's CN makes possible;
#   3. the exchange's service entry, parented on that node alias, which is what
#      authorizes it on the delegated identity API.
_six_create_bootstrap_entries() {
  local instance="$1"
  local agent_id="$2"
  local trust_domain="${SPIRE_DEV_TRUST_DOMAIN}"
  local six_unit
  six_unit="$(identity_exchange_unit "${instance}")"

  local entries_yaml
  entries_yaml="$(work_dir)/six-bootstrap-entries.yaml"
  cat >"${entries_yaml}" <<EOF
- name: spire-dev-six-agent
  spiffeID: /spire-exchange/spire-identity-exchange/${SPIRE_DEV_NODE_ID}
  parentID: ${agent_id}
  selectors:
    - systemd:id:$(agent_unit "$(six_instance)").service

- name: spire-dev-six-nodealias
  spiffeID: /spire-identity-exchange
  parentID: spiffe://${trust_domain}/spire/server
  selectors:
    - x509pop:subject:cn:spire-exchange/spire-identity-exchange

- name: spire-dev-six-service
  spiffeID: /service/spire-identity-exchange
  parentID: /spire-identity-exchange
  selectors:
    - systemd:id:${six_unit}.service
  dnsNames:
    - localhost
    - spire-identity-exchange.${trust_domain}
    - spire-identity-exchange-rest.${trust_domain}
EOF

  log_info "creating the identity-exchange bootstrap entries"

  # Created with the CLI regardless of the controller-manager setting: these are
  # this action's own entries rather than the caller's, and going through the
  # controller-manager would mix them into a manifest directory the caller may
  # also be using.
  local canonical server_sock data_file
  canonical="$(entries_normalize "${entries_yaml}" "${trust_domain}" "${agent_id}")"
  server_sock="$(server_socket "${instance}")"
  data_file="$(work_dir)/six-bootstrap-entries.json"
  entries_to_server_json "${canonical}" "${data_file}"
  entries_summary "${canonical}"

  local output rc=0
  output="$(sudo spire-server entry create -socketPath "${server_sock}" \
    -data "${data_file}" 2>&1)" || rc=$?
  printf '%s\n' "${output}"
  if [ "${rc}" -ne 0 ] &&
    ! printf '%s' "${output}" | grep -qi 'similar entry already exists'; then
    log_fail "could not create the identity-exchange bootstrap entries"
  fi
}

_six_start_second_agent() {
  local instance="$1"
  local six
  six="$(six_instance)"

  # The template refers to the primary instance's socket, which is not derivable
  # from %i inside the second instance's own unit.
  write_root_file "$(agent_env "${six}")" <<EOF
SPIRE_SERVER_ADDRESS=${SPIRE_DEV_SERVER_ADDRESS}
SPIRE_SERVER_PORT=${SPIRE_DEV_BIND_PORT}
SPIRE_LOG_LEVEL=${SPIRE_DEV_LOG_LEVEL}
SPIRE_DEV_PRIMARY_INSTANCE=${instance}
SPIRE_DEV_PRIMARY_AGENT_SOCKET=$(agent_socket "${instance}")
EOF

  write_root_file "$(agent_config "${six}")" \
    <"${SPIRE_DEV_ROOT}/conf/host/agent-six.conf"

  sudo systemctl restart "$(agent_unit "${six}")" ||
    log_fail "could not start $(agent_unit "${six}")"
  wait_for_healthcheck spire-agent "$(agent_socket "${six}")" ||
    log_fail "the identity-exchange agent instance did not become healthy"
  log_info "started $(agent_unit "${six}")"
}

_six_start_exchange() {
  local instance="$1"
  local unit
  unit="$(identity_exchange_unit "${instance}")"

  sudo systemctl daemon-reload
  sudo systemctl restart "${unit}" || log_fail "could not start ${unit}"

  # A longer budget than the other components on purpose. The exchange needs its
  # own SVID, and until the entry for it has propagated to the agent it exits and
  # is restarted by systemd every RestartSec, so "not ready yet" and "broken" look
  # the same for the first few attempts.
  # The root path is not an endpoint, so any response counts; the certificate is
  # self-signed, hence --insecure.
  wait_for_listener "https://localhost:${SPIRE_DEV_SIX_TLS_REST_PORT}" \
    "${SPIRE_DEV_TIMEOUTS_IDENTITY_EXCHANGE}" --insecure ||
    log_fail "spire-identity-exchange did not start serving on port ${SPIRE_DEV_SIX_TLS_REST_PORT}"

  log_info "spire-identity-exchange is serving on ports ${SPIRE_DEV_SIX_TLS_GRPC_PORT} (grpc) and ${SPIRE_DEV_SIX_TLS_REST_PORT} (rest)"
}
