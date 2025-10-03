#!/bin/bash
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

echo "==> Installing CRI-O..."
VERSION="1.30"

# Create keyrings directory
install -m 0755 -d /etc/apt/keyrings

# Remove old repository if it exists
rm -f /etc/apt/sources.list.d/cri-o.list
rm -f /etc/apt/keyrings/cri-o-apt-keyring.gpg

# Add CRI-O repository
curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/deb/Release.key" | \
    gpg --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/cri-o.list > /dev/null

apt-get update -qq
apt-get install -y -qq cri-o

systemctl enable crio
systemctl start crio
echo "   OK: CRI-O installed and running"
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

echo "==> Installing cosign..."
COSIGN_VERSION="v2.2.0"
wget -q "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
mv cosign-linux-amd64 /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign
echo "   OK: cosign installed"
echo ""

echo "==> Installing docker (for local registry)..."
# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository
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

echo "==> Creating directories..."
mkdir -p /etc/containers/registries.d
mkdir -p /etc/containers/keys
echo "   OK: Directories created"
echo ""

echo "==> Setup complete!"
echo ""
echo "IMPORTANT: You were added to the 'docker' group."
echo "You must REBOOT or run 'newgrp docker' for group changes to take effect."
echo ""

