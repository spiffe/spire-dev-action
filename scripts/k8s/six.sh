#!/usr/bin/env bash
# Optional: spire-identity-exchange in k8s mode.
#
# Much less work than the host equivalent, because the chart already pins the
# credential composer image and its checksum; the reference integration test
# builds that plugin from source and computes the checksum at runtime, and none of
# that is needed against a released chart.
#
# Two things the chart will not do for itself, both of which it hard-fails without:
#
#   * a TLS configuration. Exactly one of tls.externalSecret or tls.certManager
#     must be enabled. externalSecret is used here because certManager would make
#     cert-manager a prerequisite for the cluster, while a self-signed secret is
#     self-contained.
#   * at least one auth plugin. The chart ships none enabled, so
#     `identity-exchange: true` on its own would fail the render. A k8s_psat plugin
#     is configured by default so the option works out of the box; a caller who
#     wants different policy overrides it through the values input.

[ -n "${_SPIRE_DEV_K8S_SIX_SH:-}" ] && return 0
_SPIRE_DEV_K8S_SIX_SH=1

_k8s_six_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${_k8s_six_dir}/../lib/common.sh"

SPIRE_DEV_SIX_SECRET_NAME="spire-identity-exchange-tls"

# k8s_six_create_tls_secret — must run before the helm install, since the chart
# mounts the secret by name.
k8s_six_create_tls_secret() {
  require_cmd openssl kubectl

  log_group "Creating the identity-exchange TLS secret"

  local dir cert key
  dir="$(work_dir six)"
  cert="${dir}/tls.crt"
  key="${dir}/tls.key"

  local trust_domain="${SPIRE_DEV_TRUST_DOMAIN}"
  local service="${SPIRE_DEV_RELEASE_NAME}-spire-identity-exchange"

  # CA:TRUE because the certificate is its own issuer and clients pass it directly
  # as their CA bundle. The SANs cover the in-cluster service names a caller would
  # connect by.
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${key}" -out "${cert}" \
    -sha256 -days 365 -nodes \
    -subj "/CN=${service}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "subjectAltName=DNS:localhost,DNS:${service},DNS:${service}.${SPIRE_DEV_NAMESPACE},DNS:${service}.${SPIRE_DEV_NAMESPACE}.svc,DNS:${service}.${SPIRE_DEV_NAMESPACE}.svc.cluster.local,DNS:spire-identity-exchange.${trust_domain},IP:127.0.0.1" \
    2>/dev/null || log_fail "could not generate the identity-exchange certificate"

  # Recreated through apply so a re-run against the same cluster is a no-op rather
  # than an "already exists" failure.
  kubectl create secret tls "${SPIRE_DEV_SIX_SECRET_NAME}" \
    -n "${SPIRE_DEV_NAMESPACE}" \
    --cert="${cert}" --key="${key}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null ||
    log_fail "could not create the ${SPIRE_DEV_SIX_SECRET_NAME} secret"

  log_info "created secret ${SPIRE_DEV_SIX_SECRET_NAME} in ${SPIRE_DEV_NAMESPACE}"
  log_set_output identity-exchange-ca-file "${cert}"
  log_endgroup
}

# k8s_six_write_values — echoes the path to a values file wiring up the exchange.
k8s_six_write_values() {
  local file
  file="$(work_dir)/six-values.yaml"

  cat >"${file}" <<EOF
spire-server:
  # Server side of the exchange: enables the credential composer, whose image and
  # checksum the chart already pins.
  spireIdentityExchange:
    enabled: true

spire-identity-exchange:
  enabled: true
  tls:
    externalSecret:
      enabled: true
      secretName: ${SPIRE_DEV_SIX_SECRET_NAME}
  rest:
    enabled: true
  grpc:
    enabled: true
  # Works around a bug in the spire chart at ${SPIRE_DEV_CHARTS_SPIRE}:
  # templates/grpc-service.yaml reads .Values.service.annotations, where the
  # equivalent rest-service.yaml correctly reads .Values.rest.service.annotations.
  # Top-level service is null in the chart's values, so enabling grpc without this
  # fails the render with a nil pointer. Supplying an empty map makes the template's
  # with-block skip. Harmless once the chart is fixed.
  service:
    annotations: {}
  auth:
    plugins:
      # A default so that identity-exchange: true works without further input.
      # Scoped to one service account rather than the whole namespace, because a
      # default that grants more than it has to is the wrong default even in a
      # test. Override spire-identity-exchange.auth.plugins to change it.
      k8s_psat:
        enabled: true
        config:
          clusterName: ${SPIRE_DEV_CLUSTER_NAME}
          audiences:
            - spire-identity-exchange
          allowedNamespaces:
            - ${SPIRE_DEV_NAMESPACE}
          allowedServiceAccounts:
            - ${SPIRE_DEV_NAMESPACE}/default
EOF

  echo "${file}"
}
