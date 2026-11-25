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
cp "${SCRIPT_DIR}/../examples/trusted-root.json" "${CA_CERT_DIR}/registry-bundle-trusted-root.json"
cp "${SCRIPT_DIR}/../../cosign-v4-pre/examples/trusted-root-tsa.json" "${CA_CERT_DIR}/registry-v4-trusted-root.json"
# ../cosign-v4-pre v4-devcerts, when run: the EPPKI C1 dev kit's root and SubCA
DEVKIT_ROOT="${SCRIPT_DIR}/../../cosign-v4-pre/examples/devcerts/trusted-root.json"
rm -f "${CA_CERT_DIR}/registry-devcerts-trusted-root.json"
[[ ! -f "${DEVKIT_ROOT}" ]] || cp "${DEVKIT_ROOT}" "${CA_CERT_DIR}/registry-devcerts-trusted-root.json"

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

# Bundle registry (127.0.0.1:5002) - REQUIRE a Sigstore bundle, trusted root
REGISTRY_POLICY_BUNDLE=127\.0\.0\.1:5002|/etc/containerd/certs/registry-bundle-trusted-root.json

# ../cosign-v4-pre registry (127.0.0.1:5004) - REQUIRE a bundle, CA chain and TSA in the trusted root
REGISTRY_POLICY_V4=127\.0\.0\.1:5004|/etc/containerd/certs/registry-v4-trusted-root.json

# Secondary registry (127.0.0.1:5001) - ALLOW without verification
REGISTRY_POLICY_SECONDARY=127\.0\.0\.1:5001|ALLOW

# Block gcr.io - use BLOCK keyword
REGISTRY_POLICY_GCR=gcr\.io|BLOCK

# Default action for unknown registries: "allow" or "deny"
VERIFY_DEFAULT_ACTION=allow

# The test registries serve plain http; oras fetches bundles from them
VERIFY_PLAIN_HTTP=127\.0\.0\.1:500[0-4]/
CONFEOF

# ../cosign-v4-pre devcerts/ repositories, when v4-devcerts ran - REQUIRE a
# bundle by the EPPKI C1 dev kit, its SAN pinned. The verifier tries policies
# in alphabetical order: DEVCERTS_OTHER, then DEVKIT, then V4.
if [[ -f "${CA_CERT_DIR}/registry-devcerts-trusted-root.json" ]]; then
    {
        echo 'REGISTRY_POLICY_DEVKIT=127\.0\.0\.1:5004/devcerts/|/etc/containerd/certs/registry-devcerts-trusted-root.json|https://www.ericsson.com/en/about-us/security/pki'
        # devcerts/other-san pins another SAN, for test 21
        echo 'REGISTRY_POLICY_DEVCERTS_OTHER=127\.0\.0\.1:5004/devcerts/other-san[:@]|/etc/containerd/certs/registry-devcerts-trusted-root.json|https://signing.invalid'
    } >> /etc/containerd/image-verifier.conf
fi

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
echo "[OK] Transfer Service Image Verifier installed successfully"
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
