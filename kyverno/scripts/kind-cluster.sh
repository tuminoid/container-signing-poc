#!/usr/bin/env bash
# One Kind cluster plus its plain-http registries on the kind network.
# Rerunnable; the cluster is kept, its registries start empty on every run.
#
# CLUSTER names the cluster, REGISTRY_PORT the host port of its registry:3,
# ${CLUSTER}-registry, which serves referrers through the fallback tag.
# ZOT_PORT, when set, adds ${CLUSTER}-zot, zot from ZOT_IMAGE with
# ../../cosign-v4-pre/zot.json, which serves the referrers API.
#
# Workloads and Kyverno reference a registry by its kind network IP:
# Kyverno fetches Sigstore bundle referrers without honouring
# --allowInsecureRegistry, and go-containerregistry only falls back to http for
# localhost and private IPs, not for a container name.

set -eux

CLUSTER="${CLUSTER:?CLUSTER}"
REGISTRY_PORT="${REGISTRY_PORT:?REGISTRY_PORT}"
ZOT_PORT="${ZOT_PORT:-}"
ZOT_CONFIG="$(cd "$(dirname "$0")/../../cosign-v4-pre" && pwd)/zot.json"

# kind create and kind export switch the current context; everything here uses
# --context, so put back whatever the user had
PREV_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if ! kind get clusters | grep -qx "${CLUSTER}"; then
    # containerd reads per-registry config from certs.d
    cat <<EOF | kind create cluster --name="${CLUSTER}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
    [plugins."io.containerd.grpc.v1.cri".registry]
        config_path = "/etc/containerd/certs.d"
EOF
elif ! kubectl config get-contexts -o name | grep -qx "kind-${CLUSTER}"; then
    # the cluster runs, but its context left the kubeconfig, which another
    # tool writing the same file can cause
    kind export kubeconfig --name="${CLUSTER}"
fi
if [[ -n "${PREV_CONTEXT}" && "$(kubectl config current-context)" != "${PREV_CONTEXT}" ]]; then
    kubectl config use-context "${PREV_CONTEXT}"
fi

# registry name port image-and-args...: start it afresh, so no referrer of an
# earlier run survives, then pull from it over plain http under localhost:port
# and its kind IP
registry() {
    local name="$1" port="$2" ip node host
    shift 2
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker run -d -p "127.0.0.1:${port}:5000" --network kind --name "${name}" "$@"
    ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "${name}")"
    for node in $(kind get nodes --name="${CLUSTER}"); do
        for host in "localhost:${port}" "${ip}:5000"; do
            docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${host}"
            echo "[host.\"http://${ip}:5000\"]" | \
                docker exec -i "${node}" cp /dev/stdin "/etc/containerd/certs.d/${host}/hosts.toml"
        done
    done
}

registry "${CLUSTER}-registry" "${REGISTRY_PORT}" registry:3
if [[ -n "${ZOT_PORT}" ]]; then
    registry "${CLUSTER}-zot" "${ZOT_PORT}" -v "${ZOT_CONFIG}:/etc/zot/config.json:ro" \
        "${ZOT_IMAGE:?ZOT_IMAGE}"
fi

# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl --context "kind-${CLUSTER}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
    name: local-registry-hosting
    namespace: kube-public
data:
    localRegistryHosting.v1: |
        host: "localhost:${REGISTRY_PORT}"
        help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
