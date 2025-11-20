#!/usr/bin/env bash
# Generate certificate chain for CRI-O BYO-PKI signature verification
# Creates: Root CA -> Intermediate CA -> Leaf certificate
# Output: examples/ca.crt, examples/sub-ca.crt, examples/leaf.{crt,key}, examples/certificate_chain.pem

set -euo pipefail

# Create directories
OUTPUT_DIR=examples
mkdir -p "${OUTPUT_DIR}"

# Setup CA files
touch "${OUTPUT_DIR}"/index
echo 1000 > "${OUTPUT_DIR}"/serial
echo 1000 > "${OUTPUT_DIR}"/subca-serial

echo "==> Generating Root CA..."

# Generate Root CA key (ECC for efficiency)
openssl ecparam -name secp384r1 -genkey -noout -out "${OUTPUT_DIR}"/ca.key

# Create Root CA config
cat > "${OUTPUT_DIR}"/ca.conf << 'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
CN = root@example.com

[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign,digitalSignature
subjectKeyIdentifier = hash

[ca]
default_ca = CA_default

[CA_default]
database = examples/index
serial = examples/serial
private_key = examples/ca.key
certificate = examples/ca.crt
new_certs_dir = examples
default_days = 3650
default_md = sha256
policy = policy_match

[policy_match]
commonName = supplied
EOF

# Generate Root CA certificate
openssl req -new -x509 -days 365 -key "${OUTPUT_DIR}"/ca.key \
    -config "${OUTPUT_DIR}"/ca.conf \
    -out "${OUTPUT_DIR}"/ca.crt

echo "   OK: Root CA created"

echo "==> Generating Intermediate CA..."

# Intermediate CA config
cat > "${OUTPUT_DIR}"/sub-ca.conf << 'EOF'
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no

[req_dn]
CN = sub@example.com

[v3_ca]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign

[ca]
default_ca = CA_default

[CA_default]
database = examples/index
serial = examples/subca-serial
private_key = examples/sub-ca.key
certificate = examples/sub-ca.crt
new_certs_dir = examples
default_days = 1875
default_md = sha256
policy = policy_match

[policy_match]
commonName = supplied
EOF

# Generate Intermediate CA
openssl genrsa -out "${OUTPUT_DIR}"/sub-ca.key 4096
openssl req -new -config "${OUTPUT_DIR}"/sub-ca.conf \
    -key "${OUTPUT_DIR}"/sub-ca.key \
    -out "${OUTPUT_DIR}"/sub-ca.csr
openssl ca -batch -config "${OUTPUT_DIR}"/ca.conf \
    -in "${OUTPUT_DIR}"/sub-ca.csr \
    -out "${OUTPUT_DIR}"/sub-ca.crt \
    -extensions v3_ca

echo "   OK: Intermediate CA created"

echo "==> Generating Leaf Certificate..."

# Create leaf config with email identity
cat > "${OUTPUT_DIR}"/leaf.conf << 'EOF'
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
CN = signing@example.com
EOF

# Create signing config with email in subjectAltName
cat > "${OUTPUT_DIR}"/signing.conf << 'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = @alt_names

[alt_names]
email.1 = ci-build@example.com
URI.1 = https://signing.example.com
EOF

# Generate leaf key
openssl ecparam -name secp384r1 -genkey -noout -out "${OUTPUT_DIR}"/leaf.key

# Generate leaf CSR
openssl req -new -key "${OUTPUT_DIR}"/leaf.key \
    -config "${OUTPUT_DIR}"/leaf.conf \
    -out "${OUTPUT_DIR}"/leaf.csr

# Sign leaf certificate using the signing config
openssl x509 -req -days 365 \
    -in "${OUTPUT_DIR}"/leaf.csr \
    -CA "${OUTPUT_DIR}"/sub-ca.crt \
    -CAkey "${OUTPUT_DIR}"/sub-ca.key \
    -CAcreateserial \
    -extfile "${OUTPUT_DIR}"/signing.conf \
    -out "${OUTPUT_DIR}"/leaf.crt

echo "   OK: Leaf certificate created"

echo "==> Creating certificate chain..."

# Create certificate chain (intermediate + root)
cat "${OUTPUT_DIR}"/sub-ca.crt "${OUTPUT_DIR}"/ca.crt > "${OUTPUT_DIR}"/certificate_chain.pem

echo "   OK: Certificate chain created"

echo ""
echo "Certificate generation complete!"
echo "Files created in ${OUTPUT_DIR}/:"
echo "  - ca.crt                  (Root CA certificate)"
echo "  - sub-ca.crt              (Intermediate CA certificate)"
echo "  - leaf.crt                (Leaf certificate for signing)"
echo "  - leaf.key                (Leaf private key)"
echo "  - certificate_chain.pem   (Intermediate + Root)"
echo ""
echo "Identity: ci-build@example.com"
