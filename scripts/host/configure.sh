#!/usr/bin/env bash
# Writes the configuration for the deployed instance.
#
# Nothing package-shipped is edited. Configuration is layered on through the
# per-instance EnvironmentFile that the units already read, and through the
# per-instance config files that the start.sh wrappers already prefer over their
# defaults. That means a run leaves the packages' own defaults intact and the
# override for each setting lives in exactly one place.

[ -n "${_SPIRE_DEV_HOST_CONFIGURE_SH:-}" ] && return 0
_SPIRE_DEV_HOST_CONFIGURE_SH=1

_host_configure_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./paths.sh
. "${_host_configure_dir}/paths.sh"

# write_root_file <dest> — install stdin at dest, creating parent directories.
# Staged through the work dir because a redirect under sudo would need a shell.
write_root_file() {
  local dest="$1"
  local mode="${2:-0644}"
  local staged
  staged="$(work_dir staged)/$(echo "${dest}" | tr '/' '_')"
  cat >"${staged}"
  sudo mkdir -p "$(dirname "${dest}")"
  sudo install -m "${mode}" "${staged}" "${dest}"
}

# host_configure — write every config and env file for this instance.
host_configure() {
  log_group "Configuring SPIRE"

  local instance="${SPIRE_DEV_INSTANCE}"
  local trust_domain="${SPIRE_DEV_TRUST_DOMAIN}"

  # --- trust domain -------------------------------------------------------
  # Read by every unit, so it is set once here rather than per component.
  write_root_file "$(trust_domain_env)" <<EOF
SPIFFE_TRUST_DOMAIN=${trust_domain}
EOF

  # --- server -------------------------------------------------------------
  # systemd does not expand variables inside an EnvironmentFile, so anything
  # derived from another value is computed here and written literally.
  local jwt_issuer="${SPIRE_DEV_JWT_ISSUER:-https://oidc-discovery-provider.${trust_domain}}"
  write_root_file "$(server_env "${instance}")" <<EOF
SPIRE_BIND_ADDRESS=${SPIRE_DEV_BIND_ADDRESS}
SPIRE_BIND_PORT=${SPIRE_DEV_BIND_PORT}
SPIRE_LOG_LEVEL=${SPIRE_DEV_LOG_LEVEL}
SPIRE_JWT_ISSUER=${jwt_issuer}
EOF

  _write_server_config "${instance}"

  # --- agent --------------------------------------------------------------
  write_root_file "$(agent_env "${instance}")" <<EOF
SPIRE_SERVER_ADDRESS=${SPIRE_DEV_SERVER_ADDRESS}
SPIRE_SERVER_PORT=${SPIRE_DEV_BIND_PORT}
SPIRE_LOG_LEVEL=${SPIRE_DEV_LOG_LEVEL}
EOF

  _write_agent_config "${instance}"

  # --- controller-manager -------------------------------------------------
  if is_true "${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED}"; then
    write_root_file "$(controller_manager_env "${instance}")" <<EOF
METRICS_BIND_ADDRESS=${SPIRE_DEV_CONTROLLER_MANAGER_METRICS_ADDRESS}
HEALTH_PROBE_BIND_ADDRESS=${SPIRE_DEV_CONTROLLER_MANAGER_HEALTH_ADDRESS}
EOF
    write_root_file "$(controller_manager_config "${instance}")" \
      <"${SPIRE_DEV_ROOT}/conf/host/controller-manager.conf"
    sudo mkdir -p "$(static_manifest_dir "${instance}")"
  fi

  log_endgroup
}

_write_server_config() {
  local instance="$1"
  render_server_config | write_root_file "$(server_config "${instance}")"
}

# render_server_config — the server config for the enabled components, to stdout.
#
# Separate from _write_server_config so it can be rendered and inspected without
# root; tests/host-config exercises it directly.
render_server_config() {
  local template="${SPIRE_DEV_ROOT}/conf/host/server.conf"
  local extra
  extra="$(work_dir)/server-extra-plugins.conf"

  : >"${extra}"

  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE}"; then
    # spire-identity-exchange needs three additions to the server, all of them
    # taken from spire-identity-exchange's own integration test configuration
    # (tests/integration/common/server.conf):
    #
    #   CredentialComposer -- sets the CN on issued X509-SVIDs, which is what
    #     makes the x509pop selectors below able to identify the exchange.
    #   NodeAttestor x509pop in mode "spiffe" -- attests the second agent using
    #     the SVID it holds, rather than against a static CA bundle.
    #
    # The reference also sets experimental.agent_spiffe_id_as_selector, which is
    # not reproduced here: it exists so entries can be scoped to the attesting
    # agent's SPIFFE ID, and nothing this action generates does that. Leaving it
    # out keeps one less experimental setting between a working server and a
    # server that will not start.
    # Unquoted heredoc so the plugin path comes from the shared constant rather
    # than being written out a second time. The Go template braces below contain
    # no shell expansions, so they survive as written.
    cat >>"${extra}" <<EOF

    CredentialComposer "spire-identity-exchange" {
        plugin_cmd = "${SIX_CREDENTIAL_COMPOSER}"
        # Unpinned: the plugin is installed from the same package feed as the
        # server in the same job, so there is no separate artifact to pin
        # against. A real deployment should set this.
        plugin_checksum = ""
        plugin_data {}
    }

    NodeAttestor "x509pop" {
        plugin_data {
            mode = "spiffe"
            spiffe_prefix = "/spire-exchange/spire-identity-exchange/"
            agent_path_template = "/{{ .PluginName }}/spire-identity-exchange/{{ .SVIDPathTrimmed }}"
        }
    }
EOF
  fi

  # The marker is replaced rather than appended to: sed's 'r' would leave the
  # marker line itself in the installed file.
  #
  # Matched as a whole line, not as a substring. The template's own header comment
  # names the marker to explain it, and a substring match hit that line too --
  # injecting the plugin blocks at top level, outside plugins {}, which is invalid
  # HCL and stops the server from starting at all.
  awk -v extrafile="${extra}" '
    $0 == "@@EXTRA_PLUGINS@@" {
      while ((getline line < extrafile) > 0) print line
      next
    }
    { print }
  ' "${template}"
}

_write_agent_config() {
  local instance="$1"
  render_agent_config | write_root_file "$(agent_config "${instance}")"
}

# render_agent_config — the agent config for the enabled components, to stdout.
render_agent_config() {
  local template="${SPIRE_DEV_ROOT}/conf/host/agent.conf"

  # authorized_delegates gates who may use the agent's delegated identity API.
  # Empty unless something that needs it is enabled, so nothing is granted a
  # capability it has no use for.
  local delegates=""
  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE}"; then
    delegates="\"spiffe://\${SPIFFE_TRUST_DOMAIN}/service/spire-identity-exchange\""
  fi

  sed "s|@@AUTHORIZED_DELEGATES@@|${delegates}|" "${template}"
}

# host_write_join_token <instance> <parent-spiffe-id>
#
# Generates a join token and hands it to the agent through its EnvironmentFile.
# The agent's start.sh already passes ${JOIN_TOKEN:+-joinToken=...}, so the token
# never has to be written into a config file, and the agent's attested identity
# becomes the parent SPIFFE ID given here.
host_write_join_token() {
  local instance="$1"
  local parent_id="$2"
  local socket
  socket="$(server_socket "${instance}")"

  # Tracing is suppressed for the whole sequence: the token is a credential and
  # `set -x` would print it regardless of the CI system's own masking.
  log_no_trace _host_write_join_token_impl "${instance}" "${parent_id}" "${socket}"
}

_host_write_join_token_impl() {
  local instance="$1"
  local parent_id="$2"
  local socket="$3"

  local token
  token="$(sudo spire-server token generate -socketPath "${socket}" \
    -spiffeID "${parent_id}" 2>/dev/null | sed -n 's/^Token: //p')"
  [ -n "${token}" ] ||
    log_fail "could not generate a join token for ${parent_id}"

  log_mask "${token}"

  # Appended rather than rewritten so the settings written by host_configure
  # survive. Quoted because start.sh interpolates it into a command line.
  printf 'JOIN_TOKEN="%s"\n' "${token}" |
    sudo tee -a "$(agent_env "${instance}")" >/dev/null

  log_info "join token issued for ${parent_id}"
}
