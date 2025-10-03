#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/install-hooks.sh"
    exit 1
fi

echo "Installing OCI hooks..."

# Create directories
mkdir -p /usr/local/bin /etc/containerd/keys /etc/containerd/oci-hooks.d

# Install hook script
cp "${PROJECT_DIR}/hooks/verify-signature.sh" /usr/local/bin/verify-signature-hook
chmod +x /usr/local/bin/verify-signature-hook

# Install hook configuration
cp "${PROJECT_DIR}/hooks/oci-hooks.json" /etc/containerd/oci-hooks.d/

# Install public key
cp "${PROJECT_DIR}/examples/cosign.pub" /etc/containerd/keys/cosign.pub

echo "OK: Hooks installed"
