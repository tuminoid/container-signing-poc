#!/usr/bin/env bash
# devcerts.sh: one container signing certificate of the EPPKI C1 dev kit, laid
# out as gencrt.sh lays out its own, so it drops in as CERT_SCRIPT: leaf.key,
# leaf.crt, sub-ca.crt (its issuer, found by CN), ca.crt (the kit's root) and
# certificate_chain.pem (sub-ca.crt, ca.crt), in OUTPUT_DIR.
#
#   DEVCERTS    absolute path of the extracted kit, which stays outside the
#               repository
#   DEV_CERT    certificate under cont-certs/, default the valid one
#   OUTPUT_DIR  default examples

set -euo pipefail

KIT="${DEVCERTS:?DEVCERTS must name the extracted dev kit}"
CERT="${DEV_CERT:-SSW_DEV_OK_CONT_202101010000_C1_2_1}"
OUT="${OUTPUT_DIR:-examples}"

issuer="$(openssl x509 -in "${KIT}/cont-certs/${CERT}.pem" -noout -issuer -nameopt multiline |
	sed -n 's/^ *commonName *= //p')"
mkdir -p "${OUT}"
install -m 600 "${KIT}/cont-certs/${CERT}.key" "${OUT}/leaf.key"
cp "${KIT}/cont-certs/${CERT}.pem" "${OUT}/leaf.crt"
cp "${KIT}/${issuer}.cacert.pem" "${OUT}/sub-ca.crt"
cp "${KIT}/SSW_Root_CA_C1_dev.cacert.pem" "${OUT}/ca.crt"
cat "${OUT}/sub-ca.crt" "${OUT}/ca.crt" > "${OUT}/certificate_chain.pem"
