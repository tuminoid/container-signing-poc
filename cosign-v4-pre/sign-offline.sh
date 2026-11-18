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
#
# Environment, see README.md:
#   KEY           signing key, PEM; stands in for the signing server
#   LEAF          leaf certificate, PEM, with an email or URI SAN
#   WORK_DIR      directory for statement, PAE, signature and bundle.json
#   INTERMEDIATE  optional: intermediate CA certificate, PEM. Set, the bundle
#                 carries leaf plus intermediate; unset, the leaf alone
#   TSA_URL       optional: RFC 3161 timestamp authority. Set, the bundle
#                 carries a signed timestamp over the signature
#   PLAIN_HTTP    true (default) for a plain http registry, false for TLS. A
#                 registry CA outside the system roots goes in SSL_CERT_FILE
#
# Kyverno admits only the leaf alone with a timestamp: INTERMEDIATE unset,
# TSA_URL set, the intermediate in the verifier's trusted root.

set -euo pipefail

IMAGE_REF="${1:?usage: sign-offline.sh <registry>/<repo>@sha256:<digest>}"
KEY="${KEY:?KEY must point to the signing key}"
LEAF="${LEAF:?LEAF must point to the leaf certificate}"
WORK_DIR="${WORK_DIR:?WORK_DIR must name a directory for the signing files}"
INTERMEDIATE="${INTERMEDIATE:-}"
TSA_URL="${TSA_URL:-}"
PLAIN_HTTP="${PLAIN_HTTP:-true}"
# oras runs from WORK_DIR, so a relative SSL_CERT_FILE is resolved here
if [[ -n "${SSL_CERT_FILE:-}" ]]; then
	SSL_CERT_FILE="$(realpath "${SSL_CERT_FILE}")"
	export SSL_CERT_FILE
fi

if [[ ! "${IMAGE_REF}" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]]; then
	echo "error: ${IMAGE_REF} is not a <registry>/<repo>@sha256:<digest> reference" >&2
	exit 1
fi
DIGEST="${IMAGE_REF#*@}"
DIGEST_HEX="${DIGEST#sha256:}"

PAYLOAD_TYPE="application/vnd.in-toto+json"
BUNDLE_MEDIA="application/vnd.dev.sigstore.bundle.v0.3+json"
mkdir -p "${WORK_DIR}"

der_b64() {
	# DER bytes of a PEM certificate, base64 without line wrapping.
	openssl x509 -in "$1" -outform DER | base64 -w0
}

# The hash cosign's verifier uses for the leaf key: SHA-256 for RSA, which
# openssl signs with PKCS#1 v1.5 padding by default, and the curve's own hash
# for ECDSA. Any other choice fails verification or falls back to cosign's
# compatibility verifier.
case "$(openssl x509 -in "${LEAF}" -noout -pubkey | openssl pkey -pubin -noout -text)" in
*"NIST CURVE: P-256"*) HASH=sha256 ;;
*"NIST CURVE: P-384"*) HASH=sha384 ;;
*"NIST CURVE: P-521"*) HASH=sha512 ;;
*Modulus:*) HASH=sha256 ;;
*) echo "error: ${LEAF}: only RSA and ECDSA P-256, P-384, P-521 leaves are supported" >&2; exit 1 ;;
esac

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
}' | tr -d '\n' > "${WORK_DIR}/statement.json"

# DSSE pre-authentication encoding:
#   DSSEv1 SP len(type) SP type SP len(payload) SP payload
# Lengths are byte counts taken from the file, never shell string length.
payload_len=$(wc -c < "${WORK_DIR}/statement.json")
type_len=${#PAYLOAD_TYPE}
{
	printf 'DSSEv1 %d %s %d ' "${type_len}" "${PAYLOAD_TYPE}" "${payload_len}"
	cat "${WORK_DIR}/statement.json"
} > "${WORK_DIR}/payload.pae"
echo "    wrote statement.json and payload.pae (this is what gets uploaded)"

# ---------------------------------------------------------------------------
# Role 2: signing server, asynchronous.
# In production this is a separate host with the key in an HSM, signing with
# openssl-compatible options and NOT running cosign. It may answer much later.
# ---------------------------------------------------------------------------
echo "==> [signing server] signing the PAE with openssl -${HASH} (stand-in for HSM)"
openssl dgst "-${HASH}" -sign "${KEY}" \
	-out "${WORK_DIR}/payload.sig" "${WORK_DIR}/payload.pae"

# ---------------------------------------------------------------------------
# Role 3: client, after signing.
# Assemble the v0.3 bundle without root (the root is the verifier's trust
# anchor) and without transparency log: the leaf, or leaf plus intermediate,
# and with TSA_URL an RFC 3161 timestamp over the signature bytes, requested
# after signing.
# ---------------------------------------------------------------------------
# A raw signature carries no metadata, so check it against the leaf and the
# PAE before publishing anything; a wrong signature is hard to retract.
echo "==> [client] checking the signature against the leaf certificate"
openssl x509 -in "${LEAF}" -pubkey -noout > "${WORK_DIR}/leaf.pub"
openssl dgst "-${HASH}" -verify "${WORK_DIR}/leaf.pub" \
	-signature "${WORK_DIR}/payload.sig" "${WORK_DIR}/payload.pae"

if [[ -n "${INTERMEDIATE}" ]]; then
	material=$(jq -cn \
		--arg leaf "$(der_b64 "${LEAF}")" \
		--arg intermediate "$(der_b64 "${INTERMEDIATE}")" \
		'{
			x509CertificateChain: {
				certificates: [ { rawBytes: $leaf }, { rawBytes: $intermediate } ]
			}
		}')
else
	material=$(jq -cn --arg leaf "$(der_b64 "${LEAF}")" '{ certificate: { rawBytes: $leaf } }')
fi

if [[ -n "${TSA_URL}" ]]; then
	echo "==> [client] requesting RFC 3161 timestamp over the signature"
	openssl ts -query -data "${WORK_DIR}/payload.sig" -sha256 -cert \
		-out "${WORK_DIR}/payload.tsq"
	curl -sf -H 'Content-Type: application/timestamp-query' \
		--data-binary "@${WORK_DIR}/payload.tsq" \
		-o "${WORK_DIR}/payload.tsr" "${TSA_URL}"
	material=$(jq -c --arg ts "$(base64 -w0 < "${WORK_DIR}/payload.tsr")" \
		'. + { timestampVerificationData: { rfc3161Timestamps: [ { signedTimestamp: $ts } ] } }' \
		<<< "${material}")
fi

echo "==> [client] assembling v0.3 bundle"
jq -cn \
	--arg media "${BUNDLE_MEDIA}" \
	--argjson material "${material}" \
	--arg payload "$(base64 -w0 < "${WORK_DIR}/statement.json")" \
	--arg ptype "${PAYLOAD_TYPE}" \
	--arg sig "$(base64 -w0 < "${WORK_DIR}/payload.sig")" \
	'{
		mediaType: $media,
		verificationMaterial: $material,
		dsseEnvelope: {
			payload: $payload,
			payloadType: $ptype,
			signatures: [ { sig: $sig } ]
		}
	}' > "${WORK_DIR}/bundle.json"

# Publish as an OCI referrer of the image. oras attach handles both the
# referrers API and, on registries that lack it, the fallback tag index that
# cosign needs for discovery. Production would use exactly this; hand-rolled
# registry API calls also work but reimplement upload sessions and referrers
# fallback for no benefit. oras rejects absolute paths, so attach from inside
# WORK_DIR.
echo "==> [client] publishing bundle as OCI referrer via oras attach"
plain_http=()
[[ "${PLAIN_HTTP}" == "true" ]] && plain_http=(--plain-http)
(cd "${WORK_DIR}" && oras attach "${plain_http[@]}" \
	--artifact-type "${BUNDLE_MEDIA}" \
	--annotation "dev.sigstore.bundle.content=dsse-envelope" \
	--annotation "dev.sigstore.bundle.predicateType=https://sigstore.dev/cosign/sign/v1" \
	"${IMAGE_REF}" \
	"bundle.json:${BUNDLE_MEDIA}")

echo "[OK] bundle published, cosign was never invoked"
