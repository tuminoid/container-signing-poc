#!/bin/bash
# Test signature verification with CRI-O

set -euo pipefail

echo "==> Testing CRI-O signature verification..."
echo ""

# Check if crictl is available
if ! command -v crictl &> /dev/null; then
    echo "ERROR: crictl not found"
    echo "   Run: make setup"
    exit 1
fi

# Check if policy is configured
if [[ ! -f /etc/containers/policy.json ]]; then
    echo "ERROR: /etc/containers/policy.json not found"
    echo "   Run: sudo ./scripts/install-policy.sh"
    exit 1
fi

# Check if key exists
if [[ ! -f /etc/containers/keys/cosign.pub ]]; then
    echo "ERROR: /etc/containers/keys/cosign.pub not found"
    echo "   Run: sudo ./scripts/install-policy.sh"
    exit 1
fi

# Check if CRI-O is running
if ! systemctl is-active --quiet crio; then
    echo "ERROR: CRI-O is not running"
    echo "   Start it with: sudo systemctl start crio"
    exit 1
fi

echo "Configuration check:"
echo "  OK crictl installed"
echo "  OK policy.json exists"
echo "  OK cosign.pub exists"
echo "  OK CRI-O is running"
echo ""

# Test 1: Pull signed image
echo "==> Test 1: Pull signed image (should succeed)"
echo "   Image: 127.0.0.1:5003/alpine:3.20.3"
echo ""
if sudo crictl pull 127.0.0.1:5003/alpine:3.20.3 2>&1 | tee /tmp/crio-test-signed.log; then
    echo ""
    echo "OK: Signed image pull SUCCEEDED"
else
    echo ""
    echo "ERROR: Signed image pull FAILED"
    echo "   Make sure you ran: make test (it sets up automatically)"
    echo ""
    echo "   Check CRI-O logs: sudo journalctl -u crio -n 50"
fi
echo ""

# Test 2: Pull unsigned image
echo "==> Test 2: Pull unsigned image (should fail)"
echo "   Image: alpine:latest"
echo ""
if sudo crictl pull alpine:latest 2>&1 | tee /tmp/crio-test-unsigned.log; then
    echo ""
    echo "ERROR: Unsigned image pull SUCCEEDED (should have failed!)"
    echo "   Check policy.json configuration"
else
    echo ""
    echo "OK: Unsigned image pull FAILED as expected"
    grep -i "signature\|policy\|reject" /tmp/crio-test-unsigned.log || true
fi
echo ""

echo "==> Testing complete!"
echo ""
echo "View CRI-O logs:"
echo "  sudo journalctl -u crio -n 50"
