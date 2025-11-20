#!/usr/bin/env bash
# Install OCI hooks for containerd signature verification with BYO-PKI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/install-hooks.sh"
    exit 1
fi

echo "Installing OCI hooks with BYO-PKI certificates..."

# Create directories
mkdir -p /usr/local/bin /etc/containerd/certs /etc/containerd/oci-hooks.d

# Install hook script
cp "${PROJECT_DIR}/hooks/verify-signature.sh" /usr/local/bin/verify-signature-hook
chmod +x /usr/local/bin/verify-signature-hook

# Install hook configuration
cp "${PROJECT_DIR}/hooks/oci-hooks.json" /etc/containerd/oci-hooks.d/

# Install CA certificate for verification
cp "${PROJECT_DIR}/examples/ca.crt" /etc/containerd/certs/ca.crt
chmod 644 /etc/containerd/certs/ca.crt

echo "OK: BYO-PKI hooks installed"
echo ""
echo "Installed:"
echo "  - /usr/local/bin/verify-signature-hook"
echo "  - /etc/containerd/oci-hooks.d/oci-hooks.json"
echo "  - /etc/containerd/certs/ca.crt (Root CA)"
echo ""
echo "Hook will verify signatures with certificate chain validation"
