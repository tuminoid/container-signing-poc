#!/bin/bash
set -euo pipefail

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/clean-all.sh"
    exit 1
fi

echo "Cleaning up OCI hooks..."

# Remove hook files
rm -f /usr/local/bin/verify-signature-hook
rm -f /etc/containerd/oci-hooks.d/oci-hooks.json
rm -f /etc/containerd/keys/cosign.pub

echo "OK: Hooks cleanup complete"
