#!/usr/bin/env bash
# k8s mode: deploy SPIRE with the helm-charts-hardened charts.

[ -n "${_SPIRE_DEV_K8S_DEPLOY_SH:-}" ] && return 0
_SPIRE_DEV_K8S_DEPLOY_SH=1

_k8s_deploy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cluster.sh
. "${_k8s_deploy_dir}/cluster.sh"
# shellcheck source=../lib/entries.sh
. "${_k8s_deploy_dir}/../lib/entries.sh"

k8s_deploy() {
  k8s_resolve_controller_manager
  k8s_prepare_cluster
  k8s_install_charts
  k8s_verify
  k8s_publish_outputs
}

# k8s_resolve_controller_manager — settle the auto default.
#
# Unlike host mode the chart enables the controller-manager by default, and it is
# how the chart's own ClusterSPIFFEIDs (including the one the helm test uses) get
# created. So auto means on here, and turning it off is a deliberate choice to
# create entries with the spire-server CLI instead.
k8s_resolve_controller_manager() {
  local requested="${SPIRE_DEV_CONTROLLER_MANAGER:-auto}"
  local resolved

  case "$(printf '%s' "${requested}" | tr '[:upper:]' '[:lower:]')" in
  auto) resolved=true ;;
  *)
    if is_true "${requested}"; then
      resolved=true
    elif is_false "${requested}"; then
      resolved=false
    else
      log_fail "controller-manager must be true, false or auto; got '${requested}'"
    fi
    ;;
  esac

  if [ "${resolved}" = "false" ] && [ -n "${SPIRE_DEV_MANIFESTS_DIR}" ]; then
    log_fail "manifests-dir requires the controller-manager, but controller-manager is false. Set controller-manager: true, or express the entries with the entries input instead."
  fi

  SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED="${resolved}"
  export SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED
}

# k8s_install_charts — spire-crds first as its own release, then spire.
#
# spire-crds must be a separate release: the CRDs have to exist before the spire
# chart's controller-manager resources reference them, and helm does not order
# CRDs from a subchart against the resources that use them.
k8s_install_charts() {
  log_group "Installing the SPIRE charts"

  local repo="${SPIRE_DEV_CHARTS_REPO}"
  local namespace="${SPIRE_DEV_NAMESPACE}"
  local release="${SPIRE_DEV_RELEASE_NAME}"

  helm upgrade --install "${release}-crds" spire-crds \
    --repo "${repo}" --version "${SPIRE_DEV_CHARTS_SPIRE_CRDS}" \
    -n "${namespace}" --wait --timeout "${SPIRE_DEV_TIMEOUTS_HELM}" ||
    log_fail "could not install the spire-crds chart"

  # Composed as an array so each source is visible in the log and their order
  # (and therefore precedence) is explicit: our base values, then entries, then
  # whatever the caller supplied last so they can override anything.
  local -a value_args=()

  local base_values
  base_values="$(k8s_write_base_values)"
  value_args+=(--values "${base_values}")

  if is_true "${SPIRE_DEV_IDENTITY_EXCHANGE}"; then
    # shellcheck source=./six.sh
    . "${_k8s_deploy_dir}/six.sh"
    # The secret has to exist before the install: the chart mounts it by name.
    k8s_six_create_tls_secret
    value_args+=(--values "$(k8s_six_write_values)")
  fi

  local entries_values
  entries_values="$(k8s_write_entries_values)"
  if [ -n "${entries_values}" ]; then
    value_args+=(--values "${entries_values}")
  fi

  # Written to a file rather than read through a process substitution: this
  # function calls log_fail on bad input, and an exit inside a subshell would not
  # stop the deploy.
  local user_args_file
  user_args_file="$(work_dir)/user-value-args"
  k8s_user_value_args >"${user_args_file}"
  local arg_line
  while IFS= read -r arg_line; do
    [ -n "${arg_line}" ] && value_args+=("${arg_line}")
  done <"${user_args_file}"

  log_info "values files, in order of increasing precedence:"
  local arg
  for arg in "${value_args[@]}"; do
    [ "${arg}" = "--values" ] && continue
    log_info "  ${arg}"
    sed 's/^/      /' "${arg}"
  done

  helm upgrade --install "${release}" spire \
    --repo "${repo}" --version "${SPIRE_DEV_CHARTS_SPIRE}" \
    -n "${namespace}" \
    "${value_args[@]}" \
    --wait --timeout "${SPIRE_DEV_TIMEOUTS_HELM}" ||
    log_fail "could not install the spire chart"

  log_endgroup
}

# k8s_write_base_values — the settings this action always applies.
#
# Generated rather than shipped as a static file because the trust domain and
# cluster name come from inputs and a values file cannot reference the
# environment.
k8s_write_base_values() {
  local file
  file="$(work_dir)/base-values.yaml"

  # recommendations is deliberately left off. It turns on strictMode, which fails
  # the render unless trustDomain, clusterName, jwtIssuer and all three caSubject
  # fields are set; that is a useful guard for a production chart consumer but
  # only adds ways for a test deployment to break.
  cat >"${file}" <<EOF
global:
  spire:
    trustDomain: ${SPIRE_DEV_TRUST_DOMAIN}
    clusterName: ${SPIRE_DEV_CLUSTER_NAME}
    jwtIssuer: ${SPIRE_DEV_JWT_ISSUER:-https://oidc-discovery-provider.${SPIRE_DEV_TRUST_DOMAIN}}
    caSubject:
      country: US
      organization: spire-dev-action
      commonName: ${SPIRE_DEV_TRUST_DOMAIN}

spire-server:
  controllerManager:
    enabled: ${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED}

spiffe-oidc-discovery-provider:
  enabled: ${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER}

EOF

  # spire-identity-exchange is deliberately not set here: enabling it needs a TLS
  # secret and an auth plugin, so scripts/k8s/six.sh owns the whole block.
  echo "${file}"
}

# k8s_write_entries_values — the caller's entries as chart values, or nothing when
# there are none. Echoes the file path.
k8s_write_entries_values() {
  local combined
  combined="$(work_dir)/entries-input.yaml"
  entries_collect "${SPIRE_DEV_ENTRIES}" "${SPIRE_DEV_ENTRIES_FILE}" "${combined}"

  local canonical
  canonical="$(entries_normalize "${combined}" "${SPIRE_DEV_TRUST_DOMAIN}" \
    "spiffe://${SPIRE_DEV_TRUST_DOMAIN}/spire/server")"

  local count
  count="$(printf '%s' "${canonical}" | jq 'length')"
  [ "${count}" -eq 0 ] && return 0

  if ! is_true "${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED}"; then
    # Recorded for k8s_create_entries_with_cli, which runs after the install.
    printf '%s' "${canonical}" >"$(work_dir)/entries-canonical.json"
    return 0
  fi

  local file
  file="$(work_dir)/entries-values.yaml"
  entries_to_helm_values "${canonical}" "${file}" "spire-server"
  echo "${file}"
}

# k8s_user_value_args — the caller's `values` input as helm arguments.
#
# Each non-empty line is either a path to a values file or, if it is not a path,
# treated as inline YAML written to a file. Both are common enough in workflows
# that guessing wrong would be annoying, and a path that does not exist is much
# more likely to be a typo than intended YAML, so that case is an error.
k8s_user_value_args() {
  [ -n "${SPIRE_DEV_VALUES}" ] || return 0

  local inline
  inline="$(work_dir)/user-values.yaml"
  : >"${inline}"
  local have_inline=0

  local line
  while IFS= read -r line; do
    [ -z "${line//[[:space:]]/}" ] && continue
    if [ -f "${line}" ]; then
      printf '%s\n%s\n' "--values" "${line}"
    elif printf '%s' "${line}" | grep -qE '^[[:space:]]*[#-]|:'; then
      printf '%s\n' "${line}" >>"${inline}"
      have_inline=1
    else
      log_fail "values entry '${line}' is neither an existing file nor YAML"
    fi
  done <<<"${SPIRE_DEV_VALUES}"

  if [ "${have_inline}" -eq 1 ]; then
    yq -e '.' "${inline}" >/dev/null 2>&1 ||
      log_fail "the inline values input is not valid YAML"
    printf '%s\n%s\n' "--values" "${inline}"
  fi
}

# k8s_create_entries_with_cli — used when the controller-manager is disabled.
k8s_create_entries_with_cli() {
  local canonical_file
  canonical_file="$(work_dir)/entries-canonical.json"
  [ -f "${canonical_file}" ] || return 0

  log_group "Creating registration entries with the spire-server CLI"

  local pod
  pod="$(k8s_server_pod)"
  [ -n "${pod}" ] || log_fail "could not find the SPIRE server pod"

  local canonical
  canonical="$(cat "${canonical_file}")"
  entries_summary "${canonical}"

  local data_file
  data_file="$(work_dir)/entries.json"
  entries_to_server_json "${canonical}" "${data_file}"

  # Piped in over stdin, so nothing has to be copied into the pod first.
  local output rc=0
  output="$(kubectl exec -i -n "${SPIRE_DEV_NAMESPACE}" "${pod}" -c spire-server -- \
    spire-server entry create -data - <"${data_file}" 2>&1)" || rc=$?
  printf '%s\n' "${output}"
  if [ "${rc}" -ne 0 ]; then
    if printf '%s' "${output}" | grep -qi 'similar entry already exists'; then
      log_info "some entries already existed; continuing"
    else
      log_fail "could not create registration entries"
    fi
  fi

  log_endgroup
}

# k8s_verify — prove the deployment actually works, not just that helm succeeded.
k8s_verify() {
  local namespace="${SPIRE_DEV_NAMESPACE}"
  local release="${SPIRE_DEV_RELEASE_NAME}"

  k8s_create_entries_with_cli

  log_group "Verifying the deployment"

  local pod
  pod="$(k8s_server_pod)"
  [ -n "${pod}" ] || log_fail "could not find the SPIRE server pod in ${namespace}"
  log_info "server pod: ${pod}"

  # An entry count of zero means nothing can get an identity, which helm's own
  # --wait would not have caught.
  wait_for_k8s_entry_count "${namespace}" "${pod}" ||
    log_fail "no registration entries exist; nothing would be able to get an SVID"

  log_info "registration entries:"
  kubectl exec -n "${namespace}" "${pod}" -c spire-server -- \
    spire-server entry show 2>/dev/null | sed 's/^/  /' || true

  # The chart's own tests are the real workload attestation check: test-keys
  # fetches a JWT-SVID over the CSI-mounted workload socket and verifies it
  # against the discovery provider's JWKS.
  if is_true "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER}"; then
    log_info "running the chart's helm tests"
    helm test "${release}" -n "${namespace}" \
      --timeout "${SPIRE_DEV_TIMEOUTS_HELM_TEST}" ||
      log_fail "the chart's helm tests failed; SPIRE is deployed but not working"
  else
    log_info "skipping helm test: it depends on the OIDC discovery provider, which is disabled"
  fi

  log_endgroup
}

k8s_publish_outputs() {
  local namespace="${SPIRE_DEV_NAMESPACE}"
  local bundle_file
  bundle_file="$(work_dir)/bundle.pem"

  local pod
  pod="$(k8s_server_pod)"
  if [ -n "${pod}" ]; then
    kubectl exec -n "${namespace}" "${pod}" -c spire-server -- \
      spire-server bundle show >"${bundle_file}" 2>/dev/null ||
      log_warn "could not write the trust bundle to ${bundle_file}"
  fi

  # The CSI driver name is what a caller puts in their pod spec to mount the
  # workload API socket, so it is the single most useful output in this mode.
  local csi_driver
  csi_driver="$(kubectl get csidriver -o jsonpath='{.items[?(@.metadata.name=="csi.spiffe.io")].metadata.name}' 2>/dev/null)"
  : "${csi_driver:=csi.spiffe.io}"

  log_group "Deployment summary"
  log_set_output trust-domain "${SPIRE_DEV_TRUST_DOMAIN}"
  log_set_output namespace "${namespace}"
  log_set_output release-name "${SPIRE_DEV_RELEASE_NAME}"
  log_set_output csi-driver-name "${csi_driver}"
  log_set_output server-pod "${pod}"
  log_set_output bundle-file "${bundle_file}"
  log_set_output kubeconfig "${SPIRE_DEV_KUBECONFIG:-}"
  log_set_output work-dir "${SPIRE_DEV_WORK_DIR}"
  if is_true "${SPIRE_DEV_OIDC_DISCOVERY_PROVIDER}"; then
    log_set_output oidc-discovery-url \
      "http://${SPIRE_DEV_RELEASE_NAME}-spiffe-oidc-discovery-provider.${namespace}.svc.cluster.local"
  else
    log_set_output oidc-discovery-url ""
  fi

  log_summary "### SPIRE deployed (k8s mode)"
  log_summary ""
  log_summary "| | |"
  log_summary "|---|---|"
  log_summary "| Trust domain | \`${SPIRE_DEV_TRUST_DOMAIN}\` |"
  log_summary "| Namespace | \`${namespace}\` |"
  log_summary "| Release | \`${SPIRE_DEV_RELEASE_NAME}\` |"
  log_summary "| CSI driver | \`${csi_driver}\` |"
  log_summary "| Controller manager | \`${SPIRE_DEV_CONTROLLER_MANAGER_RESOLVED}\` |"
  log_endgroup
}
