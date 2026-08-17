#!/usr/bin/env bash
# k8s mode teardown.
#
# Opt-in, and never automatic: the deployment exists so that the steps after it
# can use it.
#
# With cluster: kind the whole cluster is deleted, which is both faster and more
# thorough than uninstalling. With an existing cluster only what this action
# installed is removed, including the cluster-scoped objects that a plain
# `helm uninstall` leaves behind.

[ -n "${_SPIRE_DEV_K8S_TEARDOWN_SH:-}" ] && return 0
_SPIRE_DEV_K8S_TEARDOWN_SH=1

_k8s_teardown_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${_k8s_teardown_dir}/../lib/common.sh"

k8s_teardown() {
  if [ "${SPIRE_DEV_CLUSTER}" = "kind" ]; then
    log_group "Deleting the kind cluster"
    if command -v kind >/dev/null 2>&1; then
      kind delete cluster --name "${SPIRE_DEV_CLUSTER_NAME}" || true
      log_info "deleted kind cluster ${SPIRE_DEV_CLUSTER_NAME}"
    else
      log_warn "kind is not available; nothing deleted"
    fi
    log_endgroup
    return 0
  fi

  local namespace="${SPIRE_DEV_NAMESPACE}"
  local release="${SPIRE_DEV_RELEASE_NAME}"

  command -v helm >/dev/null 2>&1 || {
    log_warn "helm is not available; nothing uninstalled"
    return 0
  }

  log_group "Uninstalling the SPIRE charts"
  helm uninstall "${release}" -n "${namespace}" 2>/dev/null || true
  helm uninstall "${release}-crds" -n "${namespace}" 2>/dev/null || true
  kubectl delete namespace "${namespace}" --ignore-not-found 2>/dev/null || true

  # Cluster-scoped leftovers. helm uninstall does not remove the CSIDriver or the
  # webhook configuration, and a later install in the same cluster fails or
  # misbehaves if they are stale.
  kubectl delete csidriver csi.spiffe.io --ignore-not-found 2>/dev/null || true
  kubectl delete validatingwebhookconfiguration \
    -l "app.kubernetes.io/instance=${release}" --ignore-not-found 2>/dev/null || true
  log_endgroup

  log_info "k8s teardown complete"
}
