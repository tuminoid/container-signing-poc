#!/bin/bash
# Setup Ubuntu 24.04 VM for containerd with OCI hooks signature verification
# This script is meant to be run ON THE VM, not on your laptop

set -euo pipefail

echo "==> Containerd + OCI Hooks Setup for Ubuntu 24.04"
echo ""
echo "WARNING: This script will install packages and modify system files."
echo "WARNING: Only run this on a dedicated VM, not on your laptop!"
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
    software-properties-common
echo "   OK dependencies installed"
echo ""

echo "==> Installing cri-tools (crictl)..."
CRICTL_VERSION="v1.30.0"
wget -q "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
tar zxf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin
rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
chmod +x /usr/local/bin/crictl

# Configure crictl
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo "   OK crictl installed"
echo ""

echo "==> Installing cosign..."
COSIGN_VERSION="v2.2.0"
wget -q "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
mv cosign-linux-amd64 /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign
echo "   OK cosign installed"
echo ""

echo "==> Installing docker and containerd..."
# Remove old docker if installed
apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

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
apt-get install -y -qq docker-ce docker-ce-cli containerd.io

systemctl enable docker
systemctl start docker
systemctl enable containerd
echo "   OK docker and containerd installed"
echo ""

echo "==> Configuring containerd for local registry..."

# Create containerd config directory
mkdir -p /etc/containerd

# Backup existing config
if [[ -f /etc/containerd/config.toml ]]; then
    cp /etc/containerd/config.toml /etc/containerd/config.toml.backup
fi

# Generate fresh config from containerd.io version
containerd config default > /etc/containerd/config.toml

# Set systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Configure local registry
cat >> /etc/containerd/config.toml <<'EOF'

# Local registry configuration
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."127.0.0.1:5000"]
      endpoint = ["http://127.0.0.1:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."127.0.0.1:5000".tls]
      insecure_skip_verify = true
EOF

systemctl restart containerd
if systemctl is-active --quiet containerd; then
    echo "   OK: containerd configured and running"
else
    echo "   ERROR: containerd failed to start"
    systemctl status containerd
    exit 1
fi
echo ""

echo "==> Creating directories for hooks..."
mkdir -p /usr/local/bin
mkdir -p /etc/containerd/keys
mkdir -p /etc/containerd/oci-hooks.d
echo "   OK Directories created"
echo ""

echo "==> Adding current user to docker group..."
# Add the user who invoked sudo to docker group
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
echo "IMPORTANT: You were added to the 'docker' group."
echo "You must REBOOT or run 'newgrp docker' for group changes to take effect."
echo ""
