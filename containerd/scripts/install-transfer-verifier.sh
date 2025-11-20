#!/usr/bin/env bash
# Install Transfer Service Image Verifier for containerd
# Uses a hardcoded config template - no dynamic manipulation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER_BIN_DIR="/opt/containerd/image-verifier/bin"
CA_CERT_DIR="/etc/containerd/certs"
CONFIG_FILE="/etc/containerd/config.toml"
CONFIG_TEMPLATE="${SCRIPT_DIR}/containerd-config-template.toml"

echo "==> Installing Transfer Service Image Verifier..."

# Create verifier binary directory
echo "Creating verifier directory: ${VERIFIER_BIN_DIR}"
mkdir -p "${VERIFIER_BIN_DIR}"

# Copy verifier script
echo "Installing verifier binary..."
cp "${SCRIPT_DIR}/image-verifier" "${VERIFIER_BIN_DIR}/verifier"
chmod +x "${VERIFIER_BIN_DIR}/verifier"

# Copy CA certificates
echo "Installing CA certificates..."
mkdir -p "${CA_CERT_DIR}"
cp "${SCRIPT_DIR}/../examples/ca.crt" "${CA_CERT_DIR}/registry-primary-ca.crt"

# Install containerd config from template
echo "Installing containerd configuration from template..."
if [[ ! -f "${CONFIG_TEMPLATE}" ]]; then
    echo "ERROR: Config template not found: ${CONFIG_TEMPLATE}"
    exit 1
fi

cp "${CONFIG_TEMPLATE}" "${CONFIG_FILE}"
echo "  Containerd config installed"

# Create verifier policy configuration file
echo "Creating verifier policy configuration..."
cat > /etc/containerd/image-verifier.conf <<'CONFEOF'
# Verifier Configuration - Per-Registry Policies
# Format: REGISTRY_POLICY_<NAME>=registry_pattern|ca_cert_path

# Primary registry (127.0.0.1:5000) - REQUIRE signature verification
REGISTRY_POLICY_PRIMARY=127\.0\.0\.1:5000|/etc/containerd/certs/registry-primary-ca.crt

# Secondary registry (127.0.0.1:5001) - ALLOW without verification
REGISTRY_POLICY_SECONDARY=127\.0\.0\.1:5001|ALLOW

# Block gcr.io - use BLOCK keyword
REGISTRY_POLICY_GCR=gcr\.io|BLOCK

# Default action for unknown registries: "allow" or "deny"
VERIFY_DEFAULT_ACTION=allow
CONFEOF

chmod 644 /etc/containerd/image-verifier.conf

# Restart containerd
echo "Restarting containerd..."
systemctl daemon-reload
systemctl restart containerd

# Verify containerd started successfully
sleep 2
if ! systemctl is-active --quiet containerd; then
    echo ""
    echo "ERROR: containerd failed to start!"
    echo ""
    echo "Check logs:"
    echo "  journalctl -xeu containerd.service"
    echo ""
    echo "Validate config:"
    echo "  containerd config dump"
    exit 1
fi

echo ""
echo "✓ Transfer Service Image Verifier installed successfully"
echo ""
echo "Installed components:"
echo "  - Verifier binary: ${VERIFIER_BIN_DIR}/verifier"
echo "  - Verifier config: /etc/containerd/image-verifier.conf"
echo "  - Primary registry CA: ${CA_CERT_DIR}/registry-primary-ca.crt"
echo "  - Containerd config: ${CONFIG_FILE} (from template)"
echo ""
echo "Registry verification policies:"
echo "  - 127.0.0.1:5000/*   : VERIFY with BYO-PKI CA"
echo "  - 127.0.0.1:5001/*   : ALLOW (no verification)"
echo "  - gcr.io/*           : BLOCK (rejected)"
echo "  - Unknown registries : ALLOW (VERIFY_DEFAULT_ACTION=allow)"
