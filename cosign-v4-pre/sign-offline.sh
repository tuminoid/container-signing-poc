#!/usr/bin/env bash
# sign-offline.sh: produce and publish a v0.3 Sigstore bundle WITHOUT cosign.
#
# This mirrors an asynchronous, in-house signing process:
#   1. client computes what needs signing, from the image digest alone
#   2. a signing server signs it, later, with openssl + HSM keys, no cosign
#   3. client assembles the bundle and publishes it as an OCI referrer
#
# cosign is never invoked here. Verification is a separate step (make verify).
# In production the signing server (step 2) is a separate host that holds the
# private key in an HSM and may respond hours later; steps 1 and 3 run on the
# developer/client side.
#
# Usage: ./sign-offline.sh <registry>/<repo>@sha256:<digest>

set -euo pipefail

IMAGE_REF="${1:?usage: sign-offline.sh <registry>/<repo>@sha256:<digest>}"
EXAMPLES_DIR="examples"

# Split the image reference into registry, repository and digest.
REGISTRY="${IMAGE_REF%%/*}"
rest="${IMAGE_REF#*/}"
REPO="${rest%@*}"
DIGEST="${IMAGE_REF#*@}"
DIGEST_HEX="${DIGEST#sha256:}"

PAYLOAD_TYPE="application/vnd.in-toto+json"
BUNDLE_MEDIA="application/vnd.dev.sigstore.bundle.v0.3+json"

LEAF="${EXAMPLES_DIR}/leaf.crt"
INTERMEDIATE="${EXAMPLES_DIR}/sub-ca.crt"
KEY="${EXAMPLES_DIR}/leaf.key"

der_b64() {
	# DER bytes of a PEM certificate, base64 without line wrapping.
	openssl x509 -in "$1" -outform DER | base64 -w0
}

# ---------------------------------------------------------------------------
# Role 1: client, before signing.
# The payload is derived from the image digest alone. No cosign, no registry
# state beyond the digest the developer already knows.
# ---------------------------------------------------------------------------
echo "==> [client] building in-toto statement for ${DIGEST}"
jq -cn --arg d "${DIGEST_HEX}" '{
	"_type": "https://in-toto.io/Statement/v1",
	"subject": [ { "digest": { "sha256": $d }, "annotations": {} } ],
	"predicateType": "https://sigstore.dev/cosign/sign/v1",
	"predicate": {}
}' | tr -d '\n' > "${EXAMPLES_DIR}/statement.json"

# DSSE pre-authentication encoding:
#   DSSEv1 SP len(type) SP type SP len(payload) SP payload
# Lengths are byte counts taken from the file, never shell string length.
payload_len=$(wc -c < "${EXAMPLES_DIR}/statement.json")
type_len=${#PAYLOAD_TYPE}
{
	printf 'DSSEv1 %d %s %d ' "${type_len}" "${PAYLOAD_TYPE}" "${payload_len}"
	cat "${EXAMPLES_DIR}/statement.json"
} > "${EXAMPLES_DIR}/payload.pae"
echo "    wrote statement.json and payload.pae (this is what gets uploaded)"

# ---------------------------------------------------------------------------
# Role 2: signing server, asynchronous.
# In production this is a separate host with the key in an HSM, signing with
# openssl-compatible options and NOT running cosign. It may answer much later.
# The P-384 leaf is classified by cosign as SHA-384, so sign with -sha384.
# ---------------------------------------------------------------------------
echo "==> [signing server] signing the PAE with openssl (stand-in for HSM)"
openssl dgst -sha384 -sign "${KEY}" \
	-out "${EXAMPLES_DIR}/payload.sig" "${EXAMPLES_DIR}/payload.pae"

# ---------------------------------------------------------------------------
# Role 3: client, after signing.
# Assemble the v0.3 bundle: leaf + intermediate in the chain, no root (the root
# is the verifier's trust anchor), no transparency log, no timestamp.
# ---------------------------------------------------------------------------
echo "==> [client] assembling v0.3 bundle"
jq -cn \
	--arg media "${BUNDLE_MEDIA}" \
	--arg leaf "$(der_b64 "${LEAF}")" \
	--arg intermediate "$(der_b64 "${INTERMEDIATE}")" \
	--arg payload "$(base64 -w0 < "${EXAMPLES_DIR}/statement.json")" \
	--arg ptype "${PAYLOAD_TYPE}" \
	--arg sig "$(base64 -w0 < "${EXAMPLES_DIR}/payload.sig")" \
	'{
		mediaType: $media,
		verificationMaterial: {
			x509CertificateChain: {
				certificates: [ { rawBytes: $leaf }, { rawBytes: $intermediate } ]
			}
		},
		dsseEnvelope: {
			payload: $payload,
			payloadType: $ptype,
			signatures: [ { sig: $sig } ]
		}
	}' > "${EXAMPLES_DIR}/bundle.json"

# Publish as an OCI referrer of the image. oras attach handles both the
# referrers API and, on registries that lack it, the fallback tag index that
# cosign needs for discovery. Production would use exactly this; hand-rolled
# registry API calls also work but reimplement upload sessions and referrers
# fallback for no benefit. oras rejects absolute paths, so pass a relative one.
echo "==> [client] publishing bundle as OCI referrer via oras attach"
oras attach --plain-http \
	--artifact-type "${BUNDLE_MEDIA}" \
	--annotation "dev.sigstore.bundle.content=dsse-envelope" \
	--annotation "dev.sigstore.bundle.predicateType=https://sigstore.dev/cosign/sign/v1" \
	"${REGISTRY}/${REPO}@${DIGEST}" \
	"${EXAMPLES_DIR}/bundle.json:${BUNDLE_MEDIA}"

echo "[OK] bundle published, cosign was never invoked"
