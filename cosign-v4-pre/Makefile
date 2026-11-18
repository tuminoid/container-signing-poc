# cosign "v4-pre": new Sigstore bundle format (v0.3) with a private PKI.
#
# Anticipates cosign v4, where bundles are the only format and the legacy
# `cosign attach` path is gone, so no deprecated flags are used here.
# Requires cosign >= 3.1.3 and an OCI 1.1 registry: registry:3, through the
# fallback tag, or zot, through the referrers API. See README.md.

TEST_REGISTRY := 127.0.0.1:5004
TEST_REGISTRY_NAME := cosign-v4-pre-registry
TEST_REGISTRY_IMAGE := registry:3
# Manifest deletion, for v4-dev-signatures
REGISTRY_ARGS := -e REGISTRY_STORAGE_DELETE_ENABLED=true
TEST_IMAGE := alpine
TEST_IMAGE_TAG := 3.20.3
TEST_DIGEST := sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d
TEST_IMAGE_LOCAL := $(TEST_REGISTRY)/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
TEST_DIGEST_LOCAL := sha256:33735bd63cf84d7e388d9f6d297d348c523c044410f553bd878c6d7829612735
# $(call ref,repo): the test image by digest in a repository of TEST_REGISTRY
ref = $(TEST_REGISTRY)/$(1)@$(TEST_DIGEST_LOCAL)
TEST_IMAGE_SIGN := $(call ref,$(TEST_IMAGE))
EXAMPLES_DIR := examples
SHELL := /bin/bash
BUNDLE_TYPE := application/vnd.dev.sigstore.bundle.v0.3+json
# Leaf key for gencrt.sh: ec, P-384, or rsa, RSA 4096
export LEAF_KEY ?= ec

# zot serves the OCI referrers API, which registry:3 does not. zot.json adds
# the docker2s2 compatibility the Docker-format test image needs.
ZOT_REGISTRY := 127.0.0.1:5008
ZOT_NAME := cosign-v4-pre-zot
ZOT_IMAGE := ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.23
ZOT := TEST_REGISTRY=$(ZOT_REGISTRY) TEST_REGISTRY_NAME=$(ZOT_NAME) \
	TEST_REGISTRY_IMAGE=$(ZOT_IMAGE) REGISTRY_ARGS="-v $(CURDIR)/zot.json:/etc/zot/config.json:ro"

# Stand-in for an organisation-run RFC 3161 timestamp authority. The memory
# signer issues its own chain on start; production chains it to the PKI.
TSA_NAME := cosign-v4-pre-tsa
TSA_ADDR := 127.0.0.1:5006
TSA_IMAGE := ghcr.io/sigstore/timestamp-server:v2.2.1
TSA_URL := http://$(TSA_ADDR)/api/v1/timestamp
TSA_SPEC := --tsa="url=$(TSA_URL),certificate-chain=$(EXAMPLES_DIR)/tsa-chain.pem"
TRUSTED_ROOT_TSA := $(EXAMPLES_DIR)/trusted-root-tsa.json
export TSA_BUNDLE_CHECK := .verificationMaterial | (.certificate != null) and \
	(.timestampVerificationData.rfc3161Timestamps | length == 1)

COSIGN_BIN ?= cosign
# 3.1.3 is the first release shipping sigstore-go v1.2.2, required to chain an
# intermediate from the bundle to a separately supplied root. cosign#3976.
COSIGN_MIN_VERSION := 3.1.3
export COSIGN_PASSWORD :=

# cosign verify without transparency log; callers add the trust and the image
VERIFY = $(COSIGN_BIN) verify --certificate-identity-regexp '.*' \
	--certificate-oidc-issuer-regexp '.*' --insecure-ignore-tlog --insecure-ignore-sct
# The admissible shape: leaf only, signed timestamp, intermediate in the root
VERIFY_TSA = $(VERIFY) --use-signed-timestamps
# $(call offline,dir): sign-offline.sh with the gencrt.sh material in dir,
# which also takes the signing files; prefix INTERMEDIATE or TSA_URL
offline = KEY=$(1)/leaf.key LEAF=$(1)/leaf.crt WORK_DIR=$(1) ./sign-offline.sh
# $(call bundles,image): digests of its bundle referrers, one per line
bundles = set -o pipefail; oras discover --plain-http --artifact-type $(BUNDLE_TYPE) --format json $(1) | \
	jq -r '.referrers[].digest'
# $(call expect-bundles,image,n): the image has exactly n bundle referrers
expect-bundles = n=$$($(call bundles,$(1)) | wc -l) || { echo "[FAIL] $(1): discovery failed"; exit 1; }; \
	[ "$$n" = "$(2)" ] || { echo "[FAIL] $(1): $$n bundle referrers, expected $(2)"; exit 1; }
# $(call bundle-json,repo@digest): the first bundle attached to the image
bundle-json = r=$(firstword $(subst @, ,$(1))); \
	m=$$(oras manifest fetch --plain-http $$r@$$($(call bundles,$(1)) | head -1)); \
	oras blob fetch --plain-http --output - $$r@$$(jq -r '.layers[0].digest' <<< "$$m")
# $(call refuse,what,error,command): the command must fail with error in its output
refuse = if out=$$($(3) 2>&1); then echo "[FAIL] $(1): accepted"; exit 1; fi; \
	grep -q '$(2)' <<< "$$out" || { echo "[FAIL] $(1): unexpected error: $$out"; exit 1; }; \
	echo "[OK] $(1): refused, $(2)"
LEAF_FAILED := failed to verify leaf certificate
# $(call copy-image,repo): the test image, without referrers, into repo
copy-image = oras cp --from-plain-http --to-plain-http $(TEST_IMAGE_LOCAL) \
	$(TEST_REGISTRY)/$(1):$(TEST_IMAGE_TAG)
# $(call trusted-root-for,gencrt.sh dir,out): CA chain of dir, plus the TSA
trusted-root-for = cat $(1)/sub-ca.crt $(1)/ca.crt > $(1)/ca-chain.pem && \
	$(COSIGN_BIN) trusted-root create $(TSA_SPEC) \
		--fulcio="url=https://private.local,certificate-chain=$(1)/ca-chain.pem" --out=$(2)

.PHONY: all check-tools registry certificates import-key signing-config \
	trusted-root setup setup-nokey sign sign-offline sign-plugin verify \
	verify-expect-fail test v4-external-offline v4-external-plugin clean \
	tsa trusted-root-tsa signing-config-tsa sign-tsa verify-tsa v4-tsa \
	relocate v4-relocate v4-external-offline-tsa v4-san-required \
	v4-offline-relocate v4-rsa v4-referrers v4-save-load v4-dev-signatures \
	v4-rotation v4-multiarch v4-shapes v4-tls v4-leaf-expiry

all:
	@echo "targets: test v4-external-offline v4-external-plugin v4-tsa v4-external-offline-tsa v4-relocate v4-san-required"
	@echo "         v4-offline-relocate v4-rsa v4-referrers v4-save-load v4-dev-signatures v4-rotation v4-multiarch v4-shapes"
	@echo "         v4-tls v4-leaf-expiry"
	@echo "         setup sign verify clean"

check-tools:
	@for t in docker openssl jq oras $(COSIGN_BIN); do \
		type -a $$t &>/dev/null || { echo "error: $$t not installed"; exit 1; }; \
	done
	@v=$$($(COSIGN_BIN) version 2>/dev/null | awk '/GitVersion/{print $$2}' | tr -d 'v'); \
	if [ "$$(printf '%s\n%s\n' "$(COSIGN_MIN_VERSION)" "$$v" | sort -V | head -1)" != "$(COSIGN_MIN_VERSION)" ]; then \
		echo "error: cosign $$v too old, need >= $(COSIGN_MIN_VERSION)"; exit 1; \
	fi; \
	echo "OK: cosign $$v"

registry:
	docker rm -f $(TEST_REGISTRY_NAME) 2>/dev/null || true
	docker run -d -p $(TEST_REGISTRY):5000 $(REGISTRY_ARGS) --name $(TEST_REGISTRY_NAME) $(TEST_REGISTRY_IMAGE)
	@for i in $$(seq 1 30); do curl -sf http://$(TEST_REGISTRY)/v2/ >/dev/null && break; sleep 1; done
	docker pull $(TEST_IMAGE):$(TEST_IMAGE_TAG)@$(TEST_DIGEST)
	docker tag $(TEST_IMAGE)@$(TEST_DIGEST) $(TEST_IMAGE_LOCAL)
	docker push $(TEST_IMAGE_LOCAL)

# Wipes examples/ first: gencrt.sh keeps an openssl CA database that refuses to
# issue the same subject twice.
certificates:
	rm -rf $(EXAMPLES_DIR)
	./gencrt.sh

# `cosign sign --key` rejects plain PEM, so the BYO key must be handed to
# cosign. This defeats external signing; see README.md.
import-key:
	@test -f $(EXAMPLES_DIR)/leaf-imported.key || \
		$(COSIGN_BIN) import-key-pair --key $(EXAMPLES_DIR)/leaf.key \
			--output-key-prefix $(EXAMPLES_DIR)/leaf-imported

# Private infrastructure has no Rekor, so strip the transparency log services.
signing-config:
	@test -f $(EXAMPLES_DIR)/signing-config.json || { \
		$(COSIGN_BIN) signing-config create --out=$(EXAMPLES_DIR)/signing-config.tmp && \
		jq 'del(.rekorTlogUrls)' $(EXAMPLES_DIR)/signing-config.tmp \
			> $(EXAMPLES_DIR)/signing-config.json; }

# Trust anchor is the ROOT CA ONLY; the intermediate travels in the bundle.
# The fulcio url key is required but never contacted, we use our own PKI.
trusted-root:
	@test -f $(EXAMPLES_DIR)/trusted-root.json || \
		$(COSIGN_BIN) trusted-root create \
			--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/ca.crt" \
			--out=$(EXAMPLES_DIR)/trusted-root.json

# setup-nokey has everything the offline flow needs: no key is handed to cosign
# and no signing config is required, since the bundle is built by hand.
setup-nokey: check-tools registry certificates trusted-root

# Full setup for the native cosign sign flow adds the imported key and the
# signing config on top of setup-nokey.
setup: setup-nokey import-key signing-config

# Chain in the bundle is the intermediate only, root comes from --trusted-root.
# --trusted-root is needed at signing time too, as cosign verifies the bundle
# it just produced. Clean first so re-running leaves one bundle, not N.
sign:
	-$(COSIGN_BIN) clean --force $(TEST_IMAGE_SIGN) 2>/dev/null
	$(COSIGN_BIN) sign \
		--key=$(EXAMPLES_DIR)/leaf-imported.key \
		--certificate=$(EXAMPLES_DIR)/leaf.crt \
		--certificate-chain=$(EXAMPLES_DIR)/sub-ca.crt \
		--signing-config=$(EXAMPLES_DIR)/signing-config.json \
		--trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		--yes \
		$(TEST_IMAGE_SIGN)

# --allow-certificate-chain is required to consume an X.509 chain from the
# bundle. Passing only the root here is the point: it proves the intermediate
# is taken from the bundle. This is cosign#3976, fixed on this codepath.
verify:
	$(VERIFY) --allow-certificate-chain --trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		$(TEST_IMAGE_SIGN)

# Without --allow-certificate-chain cosign silently falls back to the legacy
# path and reports "no signatures found". Asserted so we notice if that changes.
verify-expect-fail:
	@$(call refuse,verification without --allow-certificate-chain,no signatures found,\
		$(VERIFY) --trusted-root=$(EXAMPLES_DIR)/trusted-root.json $(TEST_IMAGE_SIGN))

test: setup sign verify verify-expect-fail
	@echo "[OK] bundle verified: intermediate from bundle, root from trusted root"

# Path B: sign without cosign, asynchronously, then publish as an OCI referrer.
# sign-offline.sh runs openssl only; cosign is never invoked at signing time.
sign-offline:
	INTERMEDIATE=$(EXAMPLES_DIR)/sub-ca.crt $(call offline,$(EXAMPLES_DIR)) $(TEST_IMAGE_SIGN)

# A fresh registry guarantees no cosign-made bundle is present, so a passing
# verify can only be explained by the hand-built bundle. Assert there is
# exactly one bundle referrer for the same reason.
v4-external-offline: setup-nokey sign-offline verify
	@$(call expect-bundles,$(TEST_IMAGE_SIGN),1)
	@echo "[OK] cosign-free bundle verified: signed by openssl, published by oras"

# Path A: synchronous external signer. cosign runs sigstore-kms-poc as a signing
# oracle via --key poc://leaf; the key stays in KEY_PEM and never reaches cosign.
# signing-config is needed (no tlog), but import-key is not: that is the point.
sign-plugin:
	-$(COSIGN_BIN) clean --force $(TEST_IMAGE_SIGN) 2>/dev/null
	PATH="$(CURDIR):$$PATH" KEY_PEM="$(CURDIR)/$(EXAMPLES_DIR)/leaf.key" \
	$(COSIGN_BIN) sign \
		--key=poc://leaf \
		--certificate=$(EXAMPLES_DIR)/leaf.crt \
		--certificate-chain=$(EXAMPLES_DIR)/sub-ca.crt \
		--signing-config=$(EXAMPLES_DIR)/signing-config.json \
		--trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		--yes \
		$(TEST_IMAGE_SIGN)

v4-external-plugin: setup-nokey signing-config sign-plugin verify verify-expect-fail
	@test ! -f $(EXAMPLES_DIR)/leaf-imported.key || \
		{ echo "[FAIL] a key was imported into cosign; external signing not proven"; exit 1; }
	@n=$$($(call bundle-json,$(TEST_IMAGE_SIGN)) | jq '.verificationMaterial.x509CertificateChain.certificates | length'); \
	if [ "$$n" != "2" ]; then echo "[FAIL] expected 2 certs (leaf+intermediate), found $$n"; exit 1; fi
	@echo "[OK] external-signer bundle verified: key never given to cosign, 2-cert chain"

# Admissible variant, the shape Kyverno can verify with a private CA. Kyverno
# never passes AllowCertificateChain, so the bundle carries the leaf only and
# the intermediate moves into the trusted root. With the tlog ignored Kyverno
# requires a signed timestamp, so a TSA joins the signing config and the
# trusted root. As a side effect, signatures outlive the leaf certificate.
tsa:
	docker rm -f $(TSA_NAME) >/dev/null 2>&1 || true
	docker run -d -p $(TSA_ADDR):3000 --name $(TSA_NAME) $(TSA_IMAGE) \
		timestamp-server serve --host 0.0.0.0 --port 3000 --timestamp-signer memory
	@for i in $$(seq 1 30); do \
		curl -sf $(TSA_URL)/certchain -o $(EXAMPLES_DIR)/tsa-chain.pem && break; sleep 1; done
	@grep -q 'BEGIN CERTIFICATE' $(EXAMPLES_DIR)/tsa-chain.pem

trusted-root-tsa: tsa
	$(call trusted-root-for,$(EXAMPLES_DIR),$(TRUSTED_ROOT_TSA))

signing-config-tsa:
	$(COSIGN_BIN) signing-config create \
		--tsa="url=$(TSA_URL),api-version=1,start-time=2024-01-01T00:00:00Z,operator=private" \
		--tsa-config=ANY --out=$(EXAMPLES_DIR)/signing-config-tsa.tmp
	jq 'del(.rekorTlogUrls)' $(EXAMPLES_DIR)/signing-config-tsa.tmp \
		> $(EXAMPLES_DIR)/signing-config-tsa.json

sign-tsa:
	-$(COSIGN_BIN) clean --force $(TEST_IMAGE_SIGN) 2>/dev/null
	$(COSIGN_BIN) sign \
		--key=$(EXAMPLES_DIR)/leaf-imported.key \
		--certificate=$(EXAMPLES_DIR)/leaf.crt \
		--signing-config=$(EXAMPLES_DIR)/signing-config-tsa.json \
		--trusted-root=$(TRUSTED_ROOT_TSA) \
		--yes \
		$(TEST_IMAGE_SIGN)

verify-tsa:
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(TEST_IMAGE_SIGN)

v4-tsa: setup trusted-root-tsa signing-config-tsa sign-tsa verify-tsa
	@$(call bundle-json,$(TEST_IMAGE_SIGN)) | jq -e "$$TSA_BUNDLE_CHECK" >/dev/null || \
		{ echo "[FAIL] expected a leaf-only bundle with one signed timestamp"; exit 1; }
	@echo "[OK] admissible bundle verified: leaf only, signed timestamp, CA chain in trusted root"

# Same admissible shape from the cosign-free asynchronous flow: the client
# timestamps the signature it got back from the signing server.
v4-external-offline-tsa: setup-nokey trusted-root-tsa
	TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(TEST_IMAGE_SIGN)
	$(MAKE) verify-tsa
	@$(call bundle-json,$(TEST_IMAGE_SIGN)) | jq -e "$$TSA_BUNDLE_CHECK" >/dev/null || \
		{ echo "[FAIL] expected a leaf-only bundle with one signed timestamp"; exit 1; }
	@echo "[OK] cosign-free admissible bundle verified: openssl signature, client-side timestamp"

# Certificate profile check: cosign takes identities from email, URI or
# other-name SANs only, so a leaf whose only SAN is a registered ID cannot be
# verified at all. The other targets' URI SAN leaf is the working profile.
v4-san-required: setup-nokey
	openssl ecparam -name secp384r1 -genkey -noout -out $(EXAMPLES_DIR)/leaf-rid.key
	openssl req -new -key $(EXAMPLES_DIR)/leaf-rid.key -subj "/CN=signing-rid" \
		-out $(EXAMPLES_DIR)/leaf-rid.csr
	openssl x509 -req -days 365 -in $(EXAMPLES_DIR)/leaf-rid.csr \
		-CA $(EXAMPLES_DIR)/sub-ca.crt -CAkey $(EXAMPLES_DIR)/sub-ca.key -CAcreateserial \
		-extfile <(printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
			'keyUsage=critical,digitalSignature' 'extendedKeyUsage=codeSigning' \
			'subjectAltName=RID:1.2.3.4') \
		-out $(EXAMPLES_DIR)/leaf-rid.crt
	INTERMEDIATE=$(EXAMPLES_DIR)/sub-ca.crt KEY=$(EXAMPLES_DIR)/leaf-rid.key \
		LEAF=$(EXAMPLES_DIR)/leaf-rid.crt WORK_DIR=$(EXAMPLES_DIR) ./sign-offline.sh $(TEST_IMAGE_SIGN)
	@if out=$$($(MAKE) -s --no-print-directory verify 2>&1); then \
		echo "[FAIL] registered-ID-only leaf verified"; exit 1; fi; \
	echo "$$out" | grep -q 'no Subject Alternative Name' || \
		{ echo "[FAIL] unexpected error: $$out"; exit 1; }
	@echo "[OK] registered-ID-only leaf rejected: the signing certificate needs an email or URI SAN"

# Air-gapped transport. cosign save/load does not carry bundles, oras does:
# copy the image with its referrers to an OCI layout, tar it, and import the
# tarball into the destination registry. The digest is unchanged. For an index,
# the referrers of its platform manifests come along too.
RELOCATE_SRC := $(TEST_IMAGE_SIGN)
RELOCATE_REPO := $(TEST_REGISTRY)/relocated/$(TEST_IMAGE)

relocate:
	rm -rf $(EXAMPLES_DIR)/layout $(EXAMPLES_DIR)/import
	oras cp -r --from-plain-http $(RELOCATE_SRC) \
		--to-oci-layout $(EXAMPLES_DIR)/layout:$(TEST_IMAGE_TAG)
	tar cf $(EXAMPLES_DIR)/layout.tar -C $(EXAMPLES_DIR) layout
	mkdir -p $(EXAMPLES_DIR)/import
	tar xf $(EXAMPLES_DIR)/layout.tar -C $(EXAMPLES_DIR)/import
	oras cp -r --from-oci-layout $(EXAMPLES_DIR)/import/layout:$(TEST_IMAGE_TAG) \
		--to-plain-http $(RELOCATE_REPO):$(TEST_IMAGE_TAG)

v4-relocate: v4-tsa relocate
	$(MAKE) verify-tsa TEST_IMAGE_SIGN=$(RELOCATE_REPO)@$(TEST_DIGEST_LOCAL)
	@echo "[OK] bundle relocated through an OCI layout tarball and verified at the destination"

# The production shape end to end with no cosign at signing time: sign,
# timestamp, publish, verify, relocate, verify at the destination.
v4-offline-relocate: v4-external-offline-tsa relocate
	$(MAKE) verify-tsa TEST_IMAGE_SIGN=$(RELOCATE_REPO)@$(TEST_DIGEST_LOCAL)
	@echo "[OK] cosign-free admissible bundle relocated and verified at the destination"

# The production algorithm: v4-offline-relocate with an RSA 4096 leaf. The
# relocated bundle must carry that leaf, with its URI SAN, and a signature that
# recovers as PKCS#1 v1.5 over a SHA-256 digest, the only RSA scheme sigstore
# accepts.
v4-rsa:
	$(MAKE) v4-offline-relocate LEAF_KEY=rsa
	@b=$$($(call bundle-json,$(RELOCATE_REPO)@$(TEST_DIGEST_LOCAL))); \
	jq -r .verificationMaterial.certificate.rawBytes <<< "$$b" | base64 -d | \
		openssl x509 -inform DER > $(EXAMPLES_DIR)/bundle-leaf.crt; \
	jq -r '.dsseEnvelope.signatures[0].sig' <<< "$$b" | base64 -d > $(EXAMPLES_DIR)/bundle.sig; \
	leaf=$$(openssl x509 -in $(EXAMPLES_DIR)/bundle-leaf.crt -noout -text); \
	grep -q 'rsaEncryption' <<< "$$leaf" && grep -q 'Public-Key: (4096 bit)' <<< "$$leaf" && \
		grep -q 'URI:https://signing.example.com' <<< "$$leaf" || \
		{ echo "[FAIL] bundle leaf is not RSA 4096 with the URI SAN"; exit 1; }; \
	openssl x509 -in $(EXAMPLES_DIR)/bundle-leaf.crt -pubkey -noout > $(EXAMPLES_DIR)/bundle-leaf.pub; \
	openssl pkeyutl -verifyrecover -pubin -inkey $(EXAMPLES_DIR)/bundle-leaf.pub \
		-in $(EXAMPLES_DIR)/bundle.sig -pkeyopt rsa_padding_mode:pkcs1 | \
		openssl asn1parse -inform DER | grep -q ':sha256' || \
		{ echo "[FAIL] signature is not PKCS#1 v1.5 over SHA-256"; exit 1; }
	@echo "[OK] RSA 4096 leaf, PKCS#1 v1.5 SHA-256: cosign-free signed, timestamped, relocated, verified"

# Referrers API versus fallback tag. registry:3 does not serve the API, so oras
# attach writes the fallback tag sha256-<digest>; zot serves it, and no tag is
# written. The same flow signs, verifies and relocates on both.
# $(call referrers,registry,API status,fallback tag status), source and copy
referrers = for repo in $(TEST_IMAGE) relocated/$(TEST_IMAGE); do \
	api=$$(curl -s -o /dev/null -w '%{http_code}' http://$(1)/v2/$$repo/referrers/$(TEST_DIGEST_LOCAL)); \
	tag=$$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.oci.image.index.v1+json' \
		http://$(1)/v2/$$repo/manifests/$(subst :,-,$(TEST_DIGEST_LOCAL))); \
	[ "$$api $$tag" = "$(2) $(3)" ] || \
		{ echo "[FAIL] $(1)/$$repo: referrers API $$api, fallback tag $$tag"; exit 1; }; done

v4-referrers:
	$(MAKE) v4-offline-relocate
	@$(call referrers,$(TEST_REGISTRY),404,200)
	$(MAKE) v4-offline-relocate $(ZOT)
	@$(call referrers,$(ZOT_REGISTRY),200,404)
	@echo "[OK] registry:3 through the fallback tag, zot through the referrers API: signed, verified, relocated"

# TLS registry: registry:3 serving https only, with a self-signed certificate
# for 127.0.0.1 that oras and cosign trust through SSL_CERT_FILE, which Go
# reads in both. sign-offline.sh with PLAIN_HTTP=false refuses the registry
# without that trust and publishes with it; cosign verifies over TLS.
TLS_REGISTRY := 127.0.0.1:5012
TLS_NAME := cosign-v4-pre-tls
TLS := $(EXAMPLES_DIR)/tls
TLS_TRUST := SSL_CERT_FILE=$(TLS)/registry.crt
TLS_IMAGE := $(TLS_REGISTRY)/$(TEST_IMAGE)@$(TEST_DIGEST_LOCAL)

v4-tls: setup-nokey trusted-root-tsa
	mkdir -p $(TLS)
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
		-subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
		-keyout $(TLS)/registry.key -out $(TLS)/registry.crt
	chmod 644 $(TLS)/registry.key
	docker rm -f $(TLS_NAME) 2>/dev/null || true
	docker run -d -p $(TLS_REGISTRY):5000 -v $(CURDIR)/$(TLS):/certs:ro \
		-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
		-e REGISTRY_HTTP_TLS_KEY=/certs/registry.key --name $(TLS_NAME) $(TEST_REGISTRY_IMAGE)
	@for i in $$(seq 1 30); do curl -sf --cacert $(TLS)/registry.crt https://$(TLS_REGISTRY)/v2/ >/dev/null && break; sleep 1; done
	@[ "$$(curl -s -o /dev/null -w '%{http_code}' http://$(TLS_REGISTRY)/v2/)" = 400 ] || \
		{ echo "[FAIL] $(TLS_REGISTRY) answers plain http"; exit 1; }
	$(TLS_TRUST) oras cp --from-plain-http $(TEST_IMAGE_LOCAL) $(TLS_REGISTRY)/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
	@$(call refuse,TLS registry without its certificate trusted,certificate signed by unknown authority,\
		PLAIN_HTTP=false $(call offline,$(EXAMPLES_DIR)) $(TLS_IMAGE))
	$(TLS_TRUST) PLAIN_HTTP=false TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(TLS_IMAGE)
	$(TLS_TRUST) $(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(TLS_IMAGE) >/dev/null
	@echo "[OK] sign-offline.sh published over TLS, cosign verified over TLS"

# Signatures outlive the leaf with a timestamp. A leaf valid for EXPIRY_SECONDS
# signs expiry/tsa with a timestamp and expiry/plain without; both verify while
# it is valid. After it expires the timestamped bundle still verifies, the
# leaf checked at the signing time, and the other fails, checked now. openssl
# ca sets the end date to the second, which openssl 3.0 x509 cannot.
EXPIRY := $(EXAMPLES_DIR)/expiry
EXPIRY_SECONDS := 40

v4-leaf-expiry: setup-nokey trusted-root-tsa
	mkdir -p $(EXPIRY)
	$(call copy-image,expiry/tsa)
	$(call copy-image,expiry/plain)
	openssl ecparam -name secp384r1 -genkey -noout -out $(EXPIRY)/leaf.key
	openssl req -new -key $(EXPIRY)/leaf.key -subj /CN=expiring@example.com -out $(EXPIRY)/leaf.csr
	openssl ca -batch -notext -rand_serial -config $(EXAMPLES_DIR)/sub-ca.conf \
		-startdate $$(date -u +%Y%m%d%H%M%SZ) -enddate $$(date -u -d '+$(EXPIRY_SECONDS) sec' +%Y%m%d%H%M%SZ) \
		-extfile $(EXAMPLES_DIR)/signing.conf -in $(EXPIRY)/leaf.csr -out $(EXPIRY)/leaf.crt
	TSA_URL=$(TSA_URL) $(call offline,$(EXPIRY)) $(call ref,expiry/tsa)
	$(call offline,$(EXPIRY)) $(call ref,expiry/plain)
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,expiry/tsa) >/dev/null
	$(VERIFY) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,expiry/plain) >/dev/null
	@openssl x509 -checkend 0 -noout -in $(EXPIRY)/leaf.crt >/dev/null || \
		{ echo "[FAIL] leaf expired before both were verified, raise EXPIRY_SECONDS"; exit 1; }
	while openssl x509 -checkend 0 -noout -in $(EXPIRY)/leaf.crt >/dev/null; do sleep 2; done
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,expiry/tsa) >/dev/null
	@$(call refuse,untimestamped bundle after leaf expiry,$(LEAF_FAILED),\
		$(VERIFY) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,expiry/plain))
	@echo "[OK] after the leaf expired, the timestamped bundle verifies and the untimestamped one fails"

# cosign save and load, the transport of the legacy flows, with a bundle. The
# saved index.json lists the image alone, so oras finds no referrer in the
# layout; cosign load still restores the bundle, and the copy verifies.
SAVE_REPO := $(TEST_REGISTRY)/loaded/$(TEST_IMAGE)

v4-save-load: v4-external-offline-tsa
	rm -rf $(EXAMPLES_DIR)/saved
	$(COSIGN_BIN) save --dir $(EXAMPLES_DIR)/saved $(TEST_IMAGE_SIGN)
	@n=$$(oras discover --oci-layout --format json $(EXAMPLES_DIR)/saved@$(TEST_DIGEST_LOCAL) | \
		jq '.referrers | length'); \
	[ "$$n" = 0 ] || { echo "[FAIL] oras finds $$n referrers in the cosign layout"; exit 1; }
	$(COSIGN_BIN) load --dir $(EXAMPLES_DIR)/saved $(SAVE_REPO)
	@$(call expect-bundles,$(SAVE_REPO)@$(TEST_DIGEST_LOCAL),1)
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(SAVE_REPO)@$(TEST_DIGEST_LOCAL) >/dev/null
	@echo "[OK] cosign save and load carry the bundle, in a layout only cosign load reads"

# Development signatures. dev/alpine carries a development and a production
# bundle, each from its own PKI behind one TSA; dev-only/alpine the development
# one alone. Each option is exported through an OCI layout tarball and checked
# at the destination against the production trusted root, which lacks the
# development CA, and the development one:
#   1. delete the development bundle, then export
#   2. copy the image alone to a clean promotion repository, sign production
#      there, export from there
#   3. export both bundles; ../kyverno/bundle-dev.mk admits this copy
DEV := $(EXAMPLES_DIR)/dev
DEV_ROOT := $(DEV)/trusted-root-tsa.json
EXPORT := $(TEST_REGISTRY)/export
# $(call ship,repo): relocate repo to export/repo; $(call shipped,repo) the copy
ship = $(MAKE) relocate RELOCATE_SRC=$(call ref,$(1)) RELOCATE_REPO=$(EXPORT)/$(1)
shipped = $(EXPORT)/$(1)@$(TEST_DIGEST_LOCAL)

v4-dev-signatures: setup-nokey trusted-root-tsa
	OUTPUT_DIR=$(DEV) ./gencrt.sh
	$(call trusted-root-for,$(DEV),$(DEV_ROOT))
	$(call copy-image,dev/$(TEST_IMAGE))
	TSA_URL=$(TSA_URL) $(call offline,$(DEV)) $(call ref,dev/$(TEST_IMAGE))
	oras cp -r --from-plain-http --to-plain-http $(call ref,dev/$(TEST_IMAGE)) \
		$(TEST_REGISTRY)/dev-only/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
	$(call bundles,$(call ref,dev/$(TEST_IMAGE))) > $(DEV)/bundle.digest
	TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(call ref,dev/$(TEST_IMAGE))
	@$(call expect-bundles,$(call ref,dev/$(TEST_IMAGE)),2)
	@$(call refuse,production root on dev-only,$(LEAF_FAILED),\
		$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,dev-only/$(TEST_IMAGE)))
	$(VERIFY_TSA) --trusted-root=$(DEV_ROOT) $(call ref,dev-only/$(TEST_IMAGE)) >/dev/null
	@echo "==> 1. delete the development bundle, then export"
	oras cp -r --from-plain-http --to-plain-http $(call ref,dev/$(TEST_IMAGE)) \
		$(TEST_REGISTRY)/deleted/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
	oras manifest delete --plain-http -f $(TEST_REGISTRY)/deleted/$(TEST_IMAGE)@$$(cat $(DEV)/bundle.digest)
	@left=$$(curl -s -H 'Accept: application/vnd.oci.image.index.v1+json' \
		http://$(TEST_REGISTRY)/v2/deleted/$(TEST_IMAGE)/manifests/$(subst :,-,$(TEST_DIGEST_LOCAL)) | \
		jq -r '.manifests[].digest'); \
	[ "$$left" = "$$($(call bundles,$(call ref,dev/$(TEST_IMAGE))) | grep -vxF "$$(cat $(DEV)/bundle.digest)")" ] || \
		{ echo "[FAIL] fallback tag index after deletion: $$left"; exit 1; }
	$(call ship,deleted/$(TEST_IMAGE))
	@$(call expect-bundles,$(call shipped,deleted/$(TEST_IMAGE)),1)
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call shipped,deleted/$(TEST_IMAGE)) >/dev/null
	@$(call refuse,development root on option 1,$(LEAF_FAILED),\
		$(VERIFY_TSA) --trusted-root=$(DEV_ROOT) $(call shipped,deleted/$(TEST_IMAGE)))
	@echo "==> 2. sign production in a clean promotion repository, export from there"
	oras cp --from-plain-http --to-plain-http $(call ref,dev/$(TEST_IMAGE)) \
		$(TEST_REGISTRY)/promotion/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
	@$(call expect-bundles,$(call ref,promotion/$(TEST_IMAGE)),0)
	TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(call ref,promotion/$(TEST_IMAGE))
	$(call ship,promotion/$(TEST_IMAGE))
	@$(call expect-bundles,$(call shipped,promotion/$(TEST_IMAGE)),1)
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call shipped,promotion/$(TEST_IMAGE)) >/dev/null
	@$(call refuse,development root on option 2,$(LEAF_FAILED),\
		$(VERIFY_TSA) --trusted-root=$(DEV_ROOT) $(call shipped,promotion/$(TEST_IMAGE)))
	@echo "==> 3. export both bundles"
	$(call ship,dev/$(TEST_IMAGE))
	@$(call expect-bundles,$(call shipped,dev/$(TEST_IMAGE)),2)
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call shipped,dev/$(TEST_IMAGE)) >/dev/null
	$(VERIFY_TSA) --trusted-root=$(DEV_ROOT) $(call shipped,dev/$(TEST_IMAGE)) >/dev/null
	@echo "[OK] development bundle deleted, avoided by promotion, or carried along: production root verifies each"

# Trust anchor rotation: CA generations gen1 and gen2, each signing
# rotation/genN with the admissible shape. One trusted root holds both, with
# validity windows gen1 until tomorrow, gen2 from yesterday; dropping gen1, or
# closing its window before the signing time, fails its signatures.
ROTATION := $(EXAMPLES_DIR)/rotation

v4-rotation: setup-nokey tsa
	mkdir -p $(ROTATION)
	for g in gen1 gen2; do \
		OUTPUT_DIR=$(EXAMPLES_DIR)/$$g ./gencrt.sh && \
		cat $(EXAMPLES_DIR)/$$g/sub-ca.crt $(EXAMPLES_DIR)/$$g/ca.crt > $(EXAMPLES_DIR)/$$g/ca-chain.pem && \
		$(call copy-image,rotation/$$g) && \
		TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)/$$g) $(call ref,rotation/$$g) || exit 1; \
	done
	$(COSIGN_BIN) trusted-root create $(TSA_SPEC) \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/gen1/ca-chain.pem,start-time=2024-01-01T00:00:00Z,end-time=$$(date -u -d tomorrow +%FT%TZ)" \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/gen2/ca-chain.pem,start-time=$$(date -u -d yesterday +%FT%TZ)" \
		--out=$(ROTATION)/both.json
	$(COSIGN_BIN) trusted-root create $(TSA_SPEC) \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/gen2/ca-chain.pem,start-time=$$(date -u -d yesterday +%FT%TZ)" \
		--out=$(ROTATION)/gen2.json
	$(COSIGN_BIN) trusted-root create $(TSA_SPEC) \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/gen1/ca-chain.pem,start-time=2024-01-01T00:00:00Z,end-time=2025-01-01T00:00:00Z" \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/gen2/ca-chain.pem,start-time=$$(date -u -d yesterday +%FT%TZ)" \
		--out=$(ROTATION)/gen1-closed.json
	$(VERIFY_TSA) --trusted-root=$(ROTATION)/both.json $(call ref,rotation/gen1) >/dev/null
	$(VERIFY_TSA) --trusted-root=$(ROTATION)/both.json $(call ref,rotation/gen2) >/dev/null
	$(VERIFY_TSA) --trusted-root=$(ROTATION)/gen2.json $(call ref,rotation/gen2) >/dev/null
	@$(call refuse,gen1 signature with gen1 dropped,$(LEAF_FAILED),\
		$(VERIFY_TSA) --trusted-root=$(ROTATION)/gen2.json $(call ref,rotation/gen1))
	@$(call refuse,gen1 signature after the gen1 window,$(LEAF_FAILED),\
		$(VERIFY_TSA) --trusted-root=$(ROTATION)/gen1-closed.json $(call ref,rotation/gen1))
	@echo "[OK] both generations verify under one root; dropping gen1 or closing its window fails gen1"

# Multi-arch: v4-rsa, then two copies of a linux/amd64 plus linux/arm64 index of
# the test image. multi/index-only has a bundle on the index alone,
# multi/platform-only one on each platform manifest. Kyverno and the
# containerd verifier are checked against these.
MULTI := $(TEST_REGISTRY)/multi
MULTI_PLATFORMS := linux/amd64,linux/arm64

v4-multiarch:
	$(MAKE) v4-rsa
	oras cp --platform $(MULTI_PLATFORMS) --to-plain-http \
		docker.io/library/$(TEST_IMAGE)@$(TEST_DIGEST) $(MULTI)/index-only:$(TEST_IMAGE_TAG)
	oras cp --from-plain-http --to-plain-http $(MULTI)/index-only:$(TEST_IMAGE_TAG) \
		$(MULTI)/platform-only:$(TEST_IMAGE_TAG)
	@index=$$(oras resolve --plain-http $(MULTI)/index-only:$(TEST_IMAGE_TAG)); \
	platforms=$$(oras manifest fetch --plain-http $(MULTI)/index-only@$$index | jq -r '.manifests[].digest'); \
	[ "$$(wc -l <<< "$$platforms")" = 2 ] || { echo "[FAIL] expected 2 platforms: $$platforms"; exit 1; }; \
	set -e; \
	TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(MULTI)/index-only@$$index; \
	for p in $$platforms; do TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(MULTI)/platform-only@$$p; done; \
	$(call expect-bundles,$(MULTI)/index-only@$$index,1); \
	$(call expect-bundles,$(MULTI)/platform-only@$$index,0); \
	for p in $$platforms; do \
		$(call expect-bundles,$(MULTI)/index-only@$$p,0); \
		$(call expect-bundles,$(MULTI)/platform-only@$$p,1); \
	done; \
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(MULTI)/index-only@$$index >/dev/null; \
	for p in $$platforms; do \
		$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(MULTI)/platform-only@$$p >/dev/null; done
	@echo "[OK] multi-arch index signed on the index (index-only) and on each platform (platform-only)"

# Tripwire material for ../kyverno/bundle-shapes.mk: three cosign-free bundles
# that cosign verifies, each differing from the admissible shapes/leaf-tsa in
# one property: shapes/chain-tsa adds the intermediate, shapes/leaf drops the
# timestamp. cosign verifies the untimestamped one at the current time.
v4-shapes: setup-nokey trusted-root-tsa
	$(call copy-image,shapes/leaf-tsa)
	$(call copy-image,shapes/chain-tsa)
	$(call copy-image,shapes/leaf)
	TSA_URL=$(TSA_URL) $(call offline,$(EXAMPLES_DIR)) $(call ref,shapes/leaf-tsa)
	TSA_URL=$(TSA_URL) INTERMEDIATE=$(EXAMPLES_DIR)/sub-ca.crt \
		$(call offline,$(EXAMPLES_DIR)) $(call ref,shapes/chain-tsa)
	$(call offline,$(EXAMPLES_DIR)) $(call ref,shapes/leaf)
	$(VERIFY_TSA) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,shapes/leaf-tsa) >/dev/null
	$(VERIFY_TSA) --allow-certificate-chain --trusted-root=$(TRUSTED_ROOT_TSA) \
		$(call ref,shapes/chain-tsa) >/dev/null
	$(VERIFY) --trusted-root=$(TRUSTED_ROOT_TSA) $(call ref,shapes/leaf) >/dev/null
	@echo "[OK] three bundle shapes signed, each verified by cosign"

clean:
	rm -rf $(EXAMPLES_DIR)
	docker rm -f $(TEST_REGISTRY_NAME) $(ZOT_NAME) $(TLS_NAME) $(TSA_NAME) 2>/dev/null || true
