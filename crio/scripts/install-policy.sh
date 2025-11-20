#!/usr/bin/env bash
# Install CRI-O signature verification policy with BYO-PKI certificates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/install-policy.sh"
    exit 1
fi

echo "Installing BYO-PKI signature verification policy..."

# Create directories
mkdir -p /etc/crio
mkdir -p /etc/containers/registries.d /etc/containers/certs

# Backup existing policy if present
if [[ -f /etc/crio/policy.json ]]; then
    cp /etc/crio/policy.json /etc/crio/policy.json.bak
fi

# Install policy files
cp "${PROJECT_DIR}/config/policy.json" /etc/crio/policy.json
cp "${PROJECT_DIR}/config/registries.d/default.yaml" /etc/containers/registries.d/

# Install certificates (split into separate files as per policy.json)
cp "${PROJECT_DIR}/examples/ca.crt" /etc/containers/certs/ca-roots.pem
cp "${PROJECT_DIR}/examples/sub-ca.crt" /etc/containers/certs/ca-intermediates.pem

# Set permissions
chmod 644 /etc/crio/policy.json
chmod 644 /etc/containers/registries.d/default.yaml
chmod 644 /etc/containers/certs/ca-roots.pem
chmod 644 /etc/containers/certs/ca-intermediates.pem

# Restart CRI-O
systemctl restart crio
sleep 2

echo "OK: BYO-PKI policy installed and CRI-O restarted"
echo ""
echo "Installed:"
echo "  - /etc/crio/policy.json"
echo "  - /etc/containers/registries.d/default.yaml"
echo "  - /etc/containers/certs/ca-roots.pem (Root CA)"
echo "  - /etc/containers/certs/ca-intermediates.pem (Intermediate CA)"
echo ""
echo "Policy will verify signatures with certificate chain:"
echo "  Root CA -> Intermediate CA -> Leaf certificate"
echo "  Identity: ci-build@example.com"
