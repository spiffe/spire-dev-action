#!/usr/bin/env bash
# Cluster provisioning and namespace preparation for k8s mode.

[ -n "${_SPIRE_DEV_K8S_CLUSTER_SH:-}" ] && return 0
_SPIRE_DEV_K8S_CLUSTER_SH=1

_k8s_cluster_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/wait.sh
. "${_k8s_cluster_dir}/../lib/wait.sh"

# k8s_prepare_cluster — create a kind cluster, or verify the caller's.
k8s_prepare_cluster() {
  require_cmd kubectl helm

  if [ "${SPIRE_DEV_CLUSTER}" = "kind" ]; then
    _k8s_create_kind
  else
    log_group "Checking the cluster"
    kubectl cluster-info >/dev/null 2>&1 ||
      log_fail "no reachable Kubernetes cluster. Set cluster: kind to have this action create one, or configure a kubectl context first."
    log_info "using the existing context: $(kubectl config current-context 2>/dev/null || echo unknown)"
    kubectl version -o json 2>/dev/null | jq -r '"server: " + .serverVersion.gitVersion' || true
    log_endgroup
  fi

  _k8s_prepare_namespaces
}

_k8s_create_kind() {
  require_cmd kind docker

  log_group "Creating the kind cluster"
  local name="${SPIRE_DEV_CLUSTER_NAME}"
  local node_image="${SPIRE_DEV_KIND_NODE_IMAGE}"

  # An override of just the Kubernetes version is more convenient than making the
  # caller name a full image.
  if [ -n "${SPIRE_DEV_K8S_VERSION:-}" ]; then
    node_image="kindest/node:${SPIRE_DEV_K8S_VERSION#kindest/node:}"
  fi

  if kind get clusters 2>/dev/null | grep -qx "${name}"; then
    log_info "kind cluster '${name}' already exists; reusing it"
  else
    log_info "creating kind cluster '${name}' with ${node_image}"
    kind create cluster \
      --name "${name}" \
      --image "${node_image}" \
      --config "${SPIRE_DEV_ROOT}/conf/k8s/kind-config.yaml" \
      --wait 120s || log_fail "could not create the kind cluster"
  fi

  kubectl config use-context "kind-${name}" ||
    log_fail "could not select the kind-${name} context"

  # Recorded as an output so a caller can pass it to other tooling.
  SPIRE_DEV_KUBECONFIG="$(work_dir)/kubeconfig"
  kind get kubeconfig --name "${name}" >"${SPIRE_DEV_KUBECONFIG}"
  export SPIRE_DEV_KUBECONFIG

  log_endgroup
}

_k8s_prepare_namespaces() {
  log_group "Preparing the namespace"

  # One namespace, which is what the chart does by default: the split
  # spire-server / spire-system layout in the reference examples requires
  # global.spire.namespaces values that this action does not set.
  #
  # It has to allow privileged pods because the agent and the CSI driver mount
  # host paths, which Pod Security's restricted profile forbids.
  local namespace="${SPIRE_DEV_NAMESPACE}"

  # Idempotent: a re-run against the same cluster must not fail on an existing
  # namespace.
  kubectl create namespace "${namespace}" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null ||
    log_fail "could not create namespace ${namespace}"
  kubectl label --overwrite namespace "${namespace}" \
    "pod-security.kubernetes.io/enforce=privileged" >/dev/null ||
    log_warn "could not label namespace ${namespace} with pod-security enforce=privileged"
  log_info "namespace ${namespace} (pod-security: privileged)"

  log_endgroup
}

# k8s_server_pod — the SPIRE server pod name, discovered by label.
#
# Never assume <release>-server-0: the name depends on the release name and on
# whether the server is a StatefulSet or a Deployment. The instance label is
# included so a second release in the same namespace is not picked up by mistake.
k8s_server_pod() {
  kubectl get pods -n "${SPIRE_DEV_NAMESPACE}" \
    -l "app.kubernetes.io/name=server,app.kubernetes.io/instance=${SPIRE_DEV_RELEASE_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}
