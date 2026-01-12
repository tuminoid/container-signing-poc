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

.PHONY: all clean registry test certificates sign verify e2e clean-e2e check-tools save load pack unpack dump-sig verify-v2-sigs verify-local e2e-local

all: check-tools
	@echo "targets: test verify clean e2e verify-v2-sigs verify-local e2e-local"

check-tools:
	@type -a docker &>/dev/null || echo "error: Install docker: https://docs.docker.com/engine/install/"
	@type -a $(COSIGN_BIN) &>/dev/null || echo "error: Install cosign: https://docs.sigstore.dev/cosign/system_config/installation/"
	@type -a openssl &>/dev/null || echo "error: openssl missing"

clean:
	rm -rf $(EXAMPLES_DIR)/$(TEST_IMAGE)-image
	rm -f $(EXAMPLES_DIR)/*
	docker rm -f $(TEST_REGISTRY_NAME) 2>/dev/null

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
