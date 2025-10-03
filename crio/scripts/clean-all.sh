#!/bin/bash
set -euo pipefail

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/clean-all.sh"
    exit 1
fi

echo "Cleaning up signature verification policy..."

# Remove policy files
rm -f /etc/containers/policy.json
rm -f /etc/containers/registries.d/default.yaml
rm -f /etc/containers/keys/cosign.pub

# Restore backup if present
if [[ -f /etc/containers/policy.json.bak ]]; then
    mv /etc/containers/policy.json.bak /etc/containers/policy.json
fi

# Restart CRI-O
systemctl restart crio 2>/dev/null || true

echo "OK: Policy cleanup complete"
