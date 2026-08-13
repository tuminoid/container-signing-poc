# cosign v3 signing test (native cosign sign command)

TEST_REGISTRY := 127.0.0.1:5003
TEST_REGISTRY_NAME := cosign-v3-registry
TEST_REGISTRY_IMAGE := registry:2
TEST_IMAGE := alpine
TEST_IMAGE_TAG := 3.20.3
TEST_DIGEST := sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d
TEST_IMAGE_LOCAL := $(TEST_REGISTRY)/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
TEST_DIGEST_LOCAL := sha256:33735bd63cf84d7e388d9f6d297d348c523c044410f553bd878c6d7829612735
TEST_IMAGE_SIGN := $(TEST_REGISTRY)/$(TEST_IMAGE)@$(TEST_DIGEST_LOCAL)
EXAMPLES_DIR := examples
SHELL := /bin/bash

# Override to use locally-built cosign (e.g., COSIGN_BIN=./cosign-patched make test)
COSIGN_BIN ?= cosign

# set gencrt script (bring your own certificates) to yes to avoid generating new
# ones each time. Must be executable (bash, python, binary) with +x bit.
# must produce leaf.{crt,key},sub-ca.crt,root.crt and certificate_chain.pem
# (sub-ca.crt + root.crt combined)
CERT_SCRIPT := ./gencrt.sh

.PHONY: all clean registry test certificates sign verify e2e clean-e2e check-tools save load pack unpack dump-sig verify-v2-sigs verify-local e2e-local signing-config sign-native verify-local-native test-local-image

all: check-tools
	@echo "targets: test verify clean e2e verify-v2-sigs verify-local e2e-local test-local-image"

check-tools:
	@type -a docker &>/dev/null || echo "error: Install docker: https://docs.docker.com/engine/install/"
	@type -a $(COSIGN_BIN) &>/dev/null || echo "error: Install cosign: https://docs.sigstore.dev/cosign/system_config/installation/"
	@type -a openssl &>/dev/null || echo "error: openssl missing"
	@type -a jq &>/dev/null || echo "error: Install jq: https://jqlang.github.io/jq/download/"

clean:
	rm -rf $(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	rm -f $(EXAMPLES_DIR)/*
	docker rm -f $(TEST_REGISTRY_NAME) 2>/dev/null || true

clean-e2e: clean

registry:
	docker run -d -p $(TEST_REGISTRY):5000 --name $(TEST_REGISTRY_NAME) $(TEST_REGISTRY_IMAGE)
	docker pull $(TEST_IMAGE):$(TEST_IMAGE_TAG)@$(TEST_DIGEST)
	docker tag $(TEST_IMAGE)@$(TEST_DIGEST) $(TEST_IMAGE_LOCAL)
	docker push $(TEST_IMAGE_LOCAL)

certificates:
	$(CERT_SCRIPT)

test: check-tools registry certificates sign verify
e2e: test save load

sign:
	@echo "==> Signing with cosign v3 (using external signer for BYO-PKI compatibility)..."
	@echo "Note: cosign v3 binary uses new bundle format by default"
	$(COSIGN_BIN) generate "$(TEST_IMAGE_SIGN)" > $(EXAMPLES_DIR)/payload.json
	openssl dgst -sha256 -sign $(EXAMPLES_DIR)/leaf.key \
		-out $(EXAMPLES_DIR)/payload.sig $(EXAMPLES_DIR)/payload.json
	base64 $(EXAMPLES_DIR)/payload.sig > $(EXAMPLES_DIR)/payloadbase64.sig

	$(COSIGN_BIN) attach signature \
		--payload $(EXAMPLES_DIR)/payload.json \
		--signature $(EXAMPLES_DIR)/payloadbase64.sig \
		--certificate $(EXAMPLES_DIR)/leaf.crt \
		--certificate-chain $(EXAMPLES_DIR)/certificate_chain.pem \
		$(TEST_IMAGE_SIGN)
	@echo "OK: Image signed with cosign v3 (BYO-PKI external signer)"

signing-config:
	@echo "==> Creating signing config without transparency log..."
	$(COSIGN_BIN) signing-config create --out=$(EXAMPLES_DIR)/signing-config.json
	jq 'del(.rekorTlogUrls)' $(EXAMPLES_DIR)/signing-config.json > $(EXAMPLES_DIR)/signing-config-notlog.json
	@echo "OK: Signing config created"

sign-native: signing-config
	@echo "==> Signing with cosign v3 native signing (generates v3 bundle format)..."
	@echo "Note: Using cosign-generated keys for native signing (not BYO-PKI)"
	# Generate cosign key pair (non-interactive with empty password)
	COSIGN_PASSWORD="" $(COSIGN_BIN) generate-key-pair --output-key-prefix=$(EXAMPLES_DIR)/cosign
	# Sign with cosign-generated key (v3 bundle format)
	COSIGN_PASSWORD="" $(COSIGN_BIN) sign \
		--key=$(EXAMPLES_DIR)/cosign.key \
		--signing-config=$(EXAMPLES_DIR)/signing-config-notlog.json \
		$(TEST_IMAGE_SIGN)
	@echo "OK: Image signed with v3 native signing (v3 bundle format)"

verify:
	$(COSIGN_BIN) tree $(TEST_IMAGE_SIGN)
	$(COSIGN_BIN) verify \
		--new-bundle-format=false \
		--ca-roots=$(EXAMPLES_DIR)/ca.crt \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--private-infrastructure \
		--insecure-ignore-sct \
		$(TEST_IMAGE_SIGN)

save:
	rm -rf $(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	$(COSIGN_BIN) save \
		--dir $(EXAMPLES_DIR)/$(TEST_IMAGE)-image \
		--allow-insecure-registry=true \
		$(TEST_IMAGE_SIGN)

pack: save
	tar cf $(EXAMPLES_DIR)/$(TEST_IMAGE).tar $(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	rm -rf $(EXAMPLES_DIR)/$(TEST_IMAGE)-image

unpack:
	rm -rf $(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	tar xf $(EXAMPLES_DIR)/$(TEST_IMAGE).tar $(EXAMPLES_DIR)/$(TEST_IMAGE)-image

load: unpack
	$(COSIGN_BIN) load \
		--allow-insecure-registry=true \
		--dir $(EXAMPLES_DIR)/$(TEST_IMAGE)-image \
		$(TEST_IMAGE_LOCAL)-loaded
	$(COSIGN_BIN) tree $(TEST_IMAGE_LOCAL)-loaded
	rm -rf $(EXAMPLES_DIR)/$(TEST_IMAGE)-image

dump-sig: save
	DIGEST=$$(jq -r '.manifests[] | select(.annotations.kind == "dev.cosignproject.cosign/sigs") | .digest' $(EXAMPLES_DIR)/$(TEST_IMAGE)-image/index.json) && \
	jq . $(EXAMPLES_DIR)/$(TEST_IMAGE)-image/blobs/"$${DIGEST/:/\/}"

verify-local: save
	@echo "==> Verifying local OCI layout (testing format auto-detection)..."
	$(COSIGN_BIN) verify \
		--local-image \
		--ca-roots=$(EXAMPLES_DIR)/ca.crt \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--private-infrastructure \
		--insecure-ignore-sct \
		$(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	@echo "[OK] Local image verification with auto-detection succeeded"

e2e-local: check-tools registry certificates sign verify-local clean
	@echo "[OK] Local image E2E test completed"

verify-local-native: save
	@echo "==> Verifying local OCI layout with v3 bundle format..."
	@echo "Note: Testing patched cosign's v3 bundle + --local-image support"
	# Verify with cosign public key (no --new-bundle-format flag = auto-detect v3)
	$(COSIGN_BIN) verify \
		--local-image \
		--key=$(EXAMPLES_DIR)/cosign.pub \
		--insecure-ignore-sct \
		--insecure-ignore-tlog \
		$(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	@echo "[OK] Local image verification with v3 bundle format succeeded"

test-local-image: check-tools registry sign-native save verify-local-native clean
	@echo "[OK] v3 bundle format + local image verification test completed"

verify-v2-sigs:
	@echo "==> Testing v3 cosign verifying v2 attached signatures..."
	@echo "Setting up v2 environment..."
	@make -C ../cosign-v2 clean
	@make -C ../cosign-v2 registry certificates sign
	@echo ""
	@echo "==> Verifying v2 signatures with v3 cosign binary..."
	@V2_REGISTRY=127.0.0.1:5003; \
	V2_IMAGE=alpine:3.20.3; \
	V2_DIGEST=$$(docker inspect --format='{{index .RepoDigests 0}}' $$V2_REGISTRY/$$V2_IMAGE | cut -d@ -f2); \
	$(COSIGN_BIN) verify \
		--new-bundle-format=false \
		--ca-roots=../cosign-v2/examples/ca.crt \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--private-infrastructure \
		--insecure-ignore-sct \
		$$V2_REGISTRY/alpine@$$V2_DIGEST
	@echo ""
	@echo "[OK] v3 cosign successfully verified v2 attached signatures!"
	@make -C ../cosign-v2 clean

# ---------------------------------------------------------------------------
# Reproduction for sigstore/cosign#3976 on the LEGACY codepath:
# "Intermediate cert and root CA must come via same source for verify to succeed"
#
# Signs an image whose attached cert chain contains ONLY the intermediate
# (sub-ca), then verifies supplying ONLY the root CA as trust anchor. On the
# legacy `cosign attach signature` path this FAILS with
# "x509: certificate signed by unknown authority", reproducing the issue.
#
# Scope note: `cosign attach signature` always produces a legacy
# simple-signing artifact, so this exercises the legacy path only, regardless
# of --new-bundle-format. The issue is FIXED on the new bundle codepath as of
# cosign 3.1.3 - see ../cosign-v4-pre (its `make test` is the demonstration).
#
#   make repro-3976-legacy   # bug case + positive control
# ---------------------------------------------------------------------------
.PHONY: repro-3976-legacy sign-intermediate-only verify-expect-fail verify-trusted-root-expect-fail

# Overwrite the cert chain with the intermediate ONLY (drop the root), then sign.
sign-intermediate-only:
	@echo "==> Building attached cert chain with INTERMEDIATE ONLY (root dropped)..."
	cp $(EXAMPLES_DIR)/sub-ca.crt $(EXAMPLES_DIR)/certificate_chain.pem
	@echo "    chain certs: $$(grep -c 'BEGIN CERTIFICATE' $(EXAMPLES_DIR)/certificate_chain.pem) (intermediate only)"
	$(MAKE) sign
	@echo "    signatures on image: $$($(COSIGN_BIN) download signature $(TEST_IMAGE_SIGN) 2>/dev/null | jq -s 'length')"

# Verify with ROOT ONLY - on the legacy path this MUST fail. A pass here means
# the legacy path was fixed too, so we invert the exit status accordingly.
verify-expect-fail:
	@echo "==> [legacy path] Verifying with ROOT ONLY (--ca-roots), expecting FAILURE..."
	@if $(COSIGN_BIN) verify \
		--new-bundle-format=false \
		--ca-roots=$(EXAMPLES_DIR)/ca.crt \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--private-infrastructure \
		--insecure-ignore-sct \
		$(TEST_IMAGE_SIGN) >/dev/null 2>&1; then \
		echo "[FAIL] verification SUCCEEDED unexpectedly - legacy path appears FIXED"; exit 1; \
	else \
		echo "[OK] verification FAILED as expected - #3976 reproduced (legacy path)"; \
	fi

# Same, via the non-deprecated --trusted-root anchor, with a trusted root that
# contains ONLY the root CA. Also expected to fail on the legacy path.
verify-trusted-root-expect-fail:
	@echo "==> [legacy path] Building trusted root with ROOT CA ONLY..."
	$(COSIGN_BIN) trusted-root create \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/ca.crt" \
		--out=$(EXAMPLES_DIR)/trusted-root-rootonly.json
	@echo "==> [legacy path] Verifying with ROOT ONLY, expecting FAILURE..."
	@if $(COSIGN_BIN) verify \
		--new-bundle-format=false \
		--trusted-root=$(EXAMPLES_DIR)/trusted-root-rootonly.json \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--insecure-ignore-tlog \
		--insecure-ignore-sct \
		$(TEST_IMAGE_SIGN) >/dev/null 2>&1; then \
		echo "[FAIL] verification SUCCEEDED unexpectedly - legacy path appears FIXED"; exit 1; \
	else \
		echo "[OK] verification FAILED as expected - #3976 reproduced (trusted-root anchor)"; \
	fi

# Full reproduction: bug case first (intermediate-only chain -> fails), then the
# positive control from a clean state (full chain in same source -> passes).
repro-3976-legacy: check-tools
	@echo "########## PHASE 1: BUG - intermediate-only attached chain ##########"
	$(MAKE) clean registry certificates
	$(MAKE) sign-intermediate-only
	$(MAKE) verify-expect-fail
	$(MAKE) verify-trusted-root-expect-fail
	@echo ""
	@echo "########## PHASE 2: CONTROL - full chain (intermediate + root) ##########"
	$(MAKE) clean registry certificates
	$(MAKE) sign
	$(MAKE) verify
	@echo ""
	@echo "[OK] #3976 reproduced on the LEGACY path: intermediate-only chain fails,"
	@echo "     full chain passes. The new bundle path is fixed - see ../cosign-v4-pre"
	@echo "     (run 'make clean' to tear down the test registry)"
