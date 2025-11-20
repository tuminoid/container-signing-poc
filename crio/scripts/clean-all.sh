#!/usr/bin/env bash
# Clean up BYO-PKI signature verification policy

set -euo pipefail

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/clean-all.sh"
    exit 1
fi

echo "Cleaning up BYO-PKI signature verification policy..."

# Remove policy files
rm -f /etc/crio/policy.json
rm -f /etc/containers/registries.d/default.yaml

# Remove certificates
rm -f /etc/containers/certs/ca-roots.pem
rm -f /etc/containers/certs/ca-intermediates.pem

# Restore backup if present
if [[ -f /etc/crio/policy.json.bak ]]; then
    mv /etc/crio/policy.json.bak /etc/crio/policy.json
fi

# Restart CRI-O
systemctl restart crio 2>/dev/null || true

echo "OK: BYO-PKI policy cleanup complete"
