#!/usr/bin/env bash
# Setup Ubuntu 24.04 VM for CRI-O signature verification
# This script is meant to be run ON THE VM, not on your laptop

set -euo pipefail

echo "==> CRI-O Setup for Ubuntu 24.04"
echo ""
echo "WARNING: This script will install packages and modify system files."
echo "Only run this on a dedicated VM, not on your laptop!"
echo ""

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root or with sudo"
    echo "   Run: sudo ./scripts/setup-vm.sh"
    exit 1
fi

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

echo "==> Installing CRI-O..."
# Requires CRI-O 1.34+ with containers/image v5.34.1+ for pki field (https://github.com/containers/image/pull/2557)
CRIO_VERSION="v1.34"
K8S_VERSION="1.32"

# Create keyrings directory
install -m 0755 -d /etc/apt/keyrings

# Remove old repository if it exists
rm -f /etc/apt/sources.list.d/cri-o.list
rm -f /etc/apt/keyrings/cri-o-apt-keyring.gpg

# Add CRI-O repository - moved from pkgs.k8s.io to download.opensuse.org
curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" | \
    gpg --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/cri-o.list > /dev/null

apt-get update -qq
apt-get install -y -qq cri-o

systemctl enable crio
systemctl start crio

# Verify CRI-O version
INSTALLED_VERSION=$(crio --version | head -1 | awk '{print $3}')
COMMIT_DATE=$(crio --version | grep GitCommitDate | awk '{print $2}' | cut -d'T' -f1)
echo "   OK: CRI-O ${INSTALLED_VERSION} installed and running"
echo "   Build date: ${COMMIT_DATE}"

# Check if built after pki support was added (Feb 28, 2025)
if [[ "${COMMIT_DATE}" < "2025-02-28" ]]; then
    echo ""
    echo "   WARNING: This CRI-O version was built before Feb 28, 2025"
    echo "   The 'pki' field for X.509 certificate chain validation may not be supported"
    echo "   Consider upgrading to a newer build if signature verification fails"
fi
echo ""

echo "==> Installing cri-tools (crictl)..."
CRICTL_VERSION="v1.30.0"
wget -q "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
tar zxf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin
rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
chmod +x /usr/local/bin/crictl

# Configure crictl
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
EOF

echo "   OK: crictl installed"
echo ""

echo "==> Adding Kubernetes repository..."
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
echo "   OK: Kubernetes repository added"
echo ""

echo "==> Installing Kubernetes components..."
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
echo "   OK: Kubernetes components installed"
echo ""

echo "==> Installing cosign..."
# Cosign v3 - uses new bundle format by default
COSIGN_VERSION="v3.0.2"
wget -q "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
mv cosign-linux-amd64 /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign
echo "   OK: cosign ${COSIGN_VERSION} installed"
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
apt-get install -y -qq docker-ce docker-ce-cli

systemctl enable docker
systemctl start docker
echo "   OK: docker installed"
echo ""

echo "==> Adding current user to docker group..."
# Add the user who invoked sudo to docker group
REAL_USER="${SUDO_USER:-${USER}}"
if [[ -n "${REAL_USER}" ]] && [[ "${REAL_USER}" != "root" ]]; then
    usermod -aG docker "${REAL_USER}"
    echo "   OK: User '${REAL_USER}' added to docker group"
    echo ""
    echo "   IMPORTANT: Log out and back in for docker group to take effect!"
    echo "   Or run: newgrp docker"
else
    echo "   WARNING: Could not determine user to add to docker group"
fi
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
echo "   OK: Kubernetes prerequisites configured"
echo ""

echo "==> Creating directories..."
mkdir -p /etc/containers/registries.d
mkdir -p /etc/containers/keys
echo "   OK: Directories created"
echo ""

echo "==> Setup complete!"
echo ""
echo "Installed:"
echo "  - CRI-O ${CRIO_VERSION}"
echo "  - Kubernetes ${K8S_VERSION} (kubelet, kubeadm, kubectl)"
echo "  - crictl, cosign, docker"
echo ""
echo "IMPORTANT: You were added to the 'docker' group."
echo "You must REBOOT or run 'newgrp docker' for group changes to take effect."
echo ""
