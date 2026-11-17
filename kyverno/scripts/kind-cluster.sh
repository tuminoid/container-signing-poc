#!/usr/bin/env bash

set -eux

# 1. Registry container config unless it already exists
REG_NAME="kind-registry"
REG_PORT="5001"

# 2. Create kind cluster with containerd registry config dir enabled
# TODO: kind will eventually enable this by default and this patch will
# be unnecessary.
#
# See:
# https://github.com/kubernetes-sigs/kind/issues/2875
# https://github.com/containerd/containerd/blob/main/docs/cri/config.md#registry-configuration
# See: https://github.com/containerd/containerd/blob/main/docs/hosts.md
cat <<EOF | kind create cluster --name=kyverno --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
    [plugins."io.containerd.grpc.v1.cri".registry]
        config_path = "/etc/containerd/certs.d"
EOF

# 3. Add the registry config to the nodes
#
# This is necessary because localhost resolves to loopback addresses that are
# network-namespace local.
# In other words: localhost in the container is not localhost on the host.
#
# We want a consistent name that works from both ends, so we tell containerd to
# alias localhost:${REG_PORT} to the registry container when pulling images
# Workloads reference ${REG_NAME}:5000, the name Kyverno also resolves from
# inside the cluster, so map that over plain http too.
for node in $(kind get nodes --name=kyverno); do
    for host in "localhost:${REG_PORT}" "${REG_NAME}:5000"; do
        docker exec "${node}" mkdir -p "/etc/containerd/certs.d/${host}"
        cat <<EOF | docker exec -i "${node}" cp /dev/stdin "/etc/containerd/certs.d/${host}/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
    done
done

# 4. Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
    name: local-registry-hosting
    namespace: kube-public
data:
    localRegistryHosting.v1: |
        host: "localhost:${REG_PORT}"
        help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
