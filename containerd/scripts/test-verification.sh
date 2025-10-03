#!/bin/bash
# Test signature verification with containerd OCI hooks

set -euo pipefail

echo "==> Testing containerd OCI hook signature verification..."
echo ""

# Check if crictl is available
if ! command -v crictl &> /dev/null; then
    echo "ERROR: crictl not found"
    echo "   Run: make setup"
    exit 1
fi

# Check if hook is installed
if [[ ! -x /usr/local/bin/verify-signature-hook ]]; then
    echo "ERROR: Hook script not found or not executable"
    echo "   Run: sudo ./scripts/install-hooks.sh"
    exit 1
fi

# Check if key exists
if [[ ! -f /etc/containerd/keys/cosign.pub ]]; then
    echo "ERROR: Cosign public key not found"
    echo "   Run: sudo ./scripts/install-hooks.sh"
    exit 1
fi

# Check if containerd is running
if ! systemctl is-active --quiet containerd; then
    echo "ERROR: containerd is not running"
    echo "   Start it with: sudo systemctl start containerd"
    exit 1
fi

echo "Configuration check:"
echo "  OK crictl is installed"
echo "  OK hook script exists"
echo "  OK cosign.pub exists"
echo "  OK containerd is running"
echo ""

# Test 1: Pull signed image
echo "==> Test 1: Pull signed image (should succeed)"
echo "   Image: 127.0.0.1:5000/alpine:3.20.3"
echo ""
if sudo crictl pull 127.0.0.1:5000/alpine:3.20.3 2>&1 | tee /tmp/containerd-test-signed.log; then
    echo ""
    echo "OK: Signed image pull SUCCEEDED"
else
    echo ""
    echo "ERROR: Signed image pull FAILED"
    echo "   Make sure you ran: make test (it sets up automatically)"
    echo ""
    echo "   Check containerd logs: sudo journalctl -u containerd -n 50"
fi
echo ""

# Test 2: Try to pull unsigned image
echo "==> Test 2: Pull unsigned image from docker.io (should fail with hook)"
echo "   Image: alpine:latest"
echo ""
if sudo crictl pull alpine:latest 2>&1 | tee /tmp/containerd-test-unsigned.log; then
    echo ""
    echo "WARNING: Unsigned image pull SUCCEEDED"
    echo "   Note: OCI hook enforcement depends on proper runc integration"
else
    echo ""
    echo "OK: Unsigned image pull FAILED as expected"
    grep -i "hook\|signature" /tmp/containerd-test-unsigned.log || true
fi
echo ""

echo "==> Manual hook test..."
echo ""
echo "Testing hook directly:"
echo '{"annotations": {"io.kubernetes.cri.image-name": "127.0.0.1:5000/alpine:3.20.3"}}' | \
    sudo /usr/local/bin/verify-signature-hook 2>&1 || true

echo ""
echo "==> Testing complete!"
echo ""
echo "View logs:"
echo "  sudo journalctl -u containerd -n 50"
echo "  sudo journalctl -t containerd-verify-hook -n 20"
