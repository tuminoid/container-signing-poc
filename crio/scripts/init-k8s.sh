#!/usr/bin/env bash
# Initialize k8s cluster with CRI-O runtime

set -euo pipefail

[[ "${EUID}" -ne 0 ]] && { echo "ERROR: Run as root"; exit 1; }

IP_ADDR=$(hostname -I | awk '{print $1}')

# Skip if already initialized
kubectl get nodes &>/dev/null && { echo "K8s already initialized"; kubectl get nodes -o wide; exit 0; }

echo "==> Initializing k8s cluster with CRI-O..."
kubeadm init \
    --node-name="$(hostname)" \
    --apiserver-advertise-address="${IP_ADDR}" \
    --pod-network-cidr=192.168.0.0/16 \
    --cri-socket=unix:///var/run/crio/crio.sock

# Setup kubeconfig
REAL_USER="${SUDO_USER:-${USER}}"
if [[ -n "${REAL_USER}" ]] && [[ "${REAL_USER}" != "root" ]]; then
    USER_HOME=$(eval echo "~${REAL_USER}")
    mkdir -p "${USER_HOME}"/.kube
    cp -f /etc/kubernetes/admin.conf "${USER_HOME}"/.kube/config
    chown -R "${REAL_USER}:${REAL_USER}" "${USER_HOME}"/.kube
fi
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

echo "==> Installing Calico CNI..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml >/dev/null

echo "==> Removing control-plane taint..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo "==> Waiting for node Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Node Ready doesn't guarantee cluster resources are ready
# Wait for essential resources: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
echo "==> Waiting for cluster resources..."
sleep 5

kubectl get nodes -o wide
