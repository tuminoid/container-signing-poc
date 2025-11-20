#!/usr/bin/env bash
# Clean up Transfer Service verifier and restore default containerd config

set -euo pipefail

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Run: sudo ./scripts/clean-all.sh"
    exit 1
fi

echo "Cleaning up Transfer Service verifier..."

# Remove verifier binary
rm -rf /opt/containerd/image-verifier

# Remove certificates
rm -rf /etc/containerd/certs

# Remove verifier config file
rm -f /etc/containerd/image-verifier.conf

# Restore fresh default containerd config
echo "Restoring default containerd configuration..."
containerd config default > /etc/containerd/config.toml

# Reload systemd and restart containerd
systemctl daemon-reload
systemctl restart containerd

# Verify containerd started
sleep 2
if systemctl is-active --quiet containerd; then
    echo "OK: Transfer Service verifier cleanup complete"
    echo "    Containerd restored to default configuration"
else
    echo "ERROR: Containerd failed to start after cleanup"
    echo "Check logs: journalctl -xeu containerd.service"
    exit 1
fi
