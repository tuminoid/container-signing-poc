#!/usr/bin/env bash
# Setup Ubuntu 24.04 VM with kubeadm cluster for containerd signature verification testing

set -euo pipefail

echo "==> Containerd + Kubeadm Setup for Ubuntu 24.04"
echo ""
echo "WARNING: This script will install Kubernetes cluster."
echo "WARNING: Only run this on a dedicated VM, not on your laptop!"
echo ""

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root or with sudo"
    echo "   Run: sudo ./scripts/setup-vm.sh"
    exit 1
fi

HOSTNAME=$(hostname)
K8S_VERSION="1.32"

echo "==> Installing dependencies..."
apt-get update -qq
apt-get install -y -qq \
    jq \
    curl \
    gnupg \
    apt-transport-https \
    ca-certificates \
    software-properties-common
echo "   OK: Dependencies installed"
echo ""

echo "==> Installing cosign..."
# Cosign v3 - uses new bundle format by default
COSIGN_VERSION="v3.0.2"
wget -q "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
mv cosign-linux-amd64 /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign
echo "   OK: cosign ${COSIGN_VERSION} installed"
echo ""

echo "==> Adding Kubernetes repository..."
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
echo "   OK: Kubernetes repository added"
echo ""

echo "==> Installing containerd..."
apt-get update -qq
# Use DEBIAN_FRONTEND=noninteractive to avoid prompts
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::="--force-confold" containerd
echo "   OK: containerd installed"
echo ""

echo "==> Installing Kubernetes components..."
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
echo "   OK: Kubernetes components installed"
echo ""

echo "==> Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Add OCI hooks ConfigPath to runc runtime options
sed -i "/\[plugins\.'io\.containerd\.cri\.v1\.runtime'\.containerd\.runtimes\.runc\.options\]/a\\            ConfigPath = '/etc/containerd/oci-hooks.d'" /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
echo "   OK: containerd configured"
echo ""

echo "==> Preparing Kubernetes prerequisites..."
# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load required modules
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure system settings
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null
echo "   OK: Prerequisites configured"
echo ""

echo "==> Installing docker (for local registry)..."
# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository
# shellcheck disable=SC1091
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::="--force-confold" docker-ce docker-ce-cli

systemctl enable docker
systemctl start docker
echo "   OK: docker installed"
echo ""

echo "==> Creating directories for hooks and certificates..."
mkdir -p /usr/local/bin
mkdir -p /etc/containerd/certs
mkdir -p /etc/containerd/oci-hooks.d
echo "   OK: Directories created"
echo ""

echo "==> Adding current user to docker group..."
REAL_USER="${SUDO_USER:-${USER}}"
if [[ -n "${REAL_USER}" ]] && [[ "${REAL_USER}" != "root" ]]; then
    usermod -aG docker "${REAL_USER}"
    echo "   OK: User '${REAL_USER}' added to docker group"
else
    echo "   WARNING: Could not determine user to add to docker group"
fi
echo ""

echo "==> Setup complete!"
echo ""
echo "IMPORTANT: Log out and back in for docker group to take effect."
echo "After login, run: make run"
echo ""
