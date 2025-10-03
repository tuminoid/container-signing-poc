#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/install-policy.sh"
    exit 1
fi

echo "Installing signature verification policy..."

# Create directories
mkdir -p /etc/containers/registries.d /etc/containers/keys

# Backup existing policy if present
if [[ -f /etc/containers/policy.json ]]; then
    cp /etc/containers/policy.json /etc/containers/policy.json.bak
fi

# Install policy files
cp "${PROJECT_DIR}/config/policy.json" /etc/containers/policy.json
cp "${PROJECT_DIR}/config/registries.d/default.yaml" /etc/containers/registries.d/
cp "${PROJECT_DIR}/examples/cosign.pub" /etc/containers/keys/cosign.pub

# Set permissions
chmod 644 /etc/containers/policy.json
chmod 644 /etc/containers/registries.d/default.yaml
chmod 644 /etc/containers/keys/cosign.pub

# Restart CRI-O
systemctl restart crio
sleep 2

echo "OK: Policy installed and CRI-O restarted"
