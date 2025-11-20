#!/usr/bin/env bash
# OCI Hook for container signature verification with BYO-PKI
# This hook is called before container creation to verify image signatures

set -euo pipefail

# Configuration
CA_CERT="${CA_CERT:-/etc/containerd/certs/ca.crt}"
LOG_TAG="containerd-verify-hook"

# Read container state from stdin (OCI spec)
STATE=$(cat)

# Extract image name from annotations
IMAGE=$(echo "${STATE}" | jq -r '.annotations["io.kubernetes.cri.image-name"] // .annotations["io.cri-containerd.image.name"] // empty')

# If we can't find the image, try the process args as fallback
if [[ -z "${IMAGE}" ]] || [[ "${IMAGE}" = "null" ]]; then
    logger -t "${LOG_TAG}" "Warning: Could not extract image name from container state"
    exit 0  # Don't block if we can't determine image
fi

# Skip verification for system images (pause containers, etc)
if [[ "${IMAGE}" =~ pause|registry\.k8s\.io/pause|registry:2 ]]; then
    logger -t "${LOG_TAG}" "Skipping verification for system image: ${IMAGE}"
    exit 0
fi

# Local registry images
if [[ "${IMAGE}" =~ ^(localhost|127\.0\.0\.1):5000 ]]; then
    logger -t "${LOG_TAG}" "Verifying local registry image: ${IMAGE}"
fi

logger -t "${LOG_TAG}" "Verifying signature for image: ${IMAGE}"

# Verify signature using cosign with BYO-PKI (certificate chain validation)
if cosign verify \
    --ca-roots="${CA_CERT}" \
    --certificate-identity-regexp '.*' \
    --certificate-oidc-issuer-regexp '.*' \
    --private-infrastructure \
    --insecure-ignore-sct \
    --allow-insecure-registry \
    "${IMAGE}" >"/tmp/cosign-verify-$$.log" 2>&1; then

    logger -t "${LOG_TAG}" "OK Image signature verified with BYO-PKI certificate chain: ${IMAGE}"
    exit 0
else
    ERROR_MSG=$(cat "/tmp/cosign-verify-$$.log" 2>/dev/null || echo "Unknown error")
    logger -t "${LOG_TAG}" "ERROR Image signature verification FAILED for: ${IMAGE} - Error: ${ERROR_MSG}"
    rm -f "/tmp/cosign-verify-$$.log"
    exit 1
fi
