# cosign "v4-pre": new Sigstore bundle format (v0.3) with a private PKI.
#
# Anticipates cosign v4, where bundles are the only format and the legacy
# `cosign attach` path is gone, so no deprecated flags are used here.
# Requires cosign >= 3.1.3 and registry:3 (OCI 1.1 referrers). See README.md.

TEST_REGISTRY := 127.0.0.1:5004
TEST_REGISTRY_NAME := cosign-v4-pre-registry
TEST_REGISTRY_IMAGE := registry:3
TEST_IMAGE := alpine
TEST_IMAGE_TAG := 3.20.3
TEST_DIGEST := sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d
TEST_IMAGE_LOCAL := $(TEST_REGISTRY)/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
TEST_DIGEST_LOCAL := sha256:33735bd63cf84d7e388d9f6d297d348c523c044410f553bd878c6d7829612735
TEST_IMAGE_SIGN := $(TEST_REGISTRY)/$(TEST_IMAGE)@$(TEST_DIGEST_LOCAL)
EXAMPLES_DIR := examples
SHELL := /bin/bash

COSIGN_BIN ?= cosign
# 3.1.3 is the first release shipping sigstore-go v1.2.2, required to chain an
# intermediate from the bundle to a separately supplied root. cosign#3976.
COSIGN_MIN_VERSION := 3.1.3
export COSIGN_PASSWORD :=

.PHONY: all check-tools registry certificates import-key signing-config \
	trusted-root setup setup-nokey sign sign-offline verify \
	verify-expect-fail test v4-external-offline clean

all:
	@echo "targets: test v4-external-offline setup sign verify clean"

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
	docker run -d -p $(TEST_REGISTRY):5000 --name $(TEST_REGISTRY_NAME) $(TEST_REGISTRY_IMAGE)
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
	$(COSIGN_BIN) verify \
		--allow-certificate-chain \
		--trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--insecure-ignore-tlog \
		--insecure-ignore-sct \
		$(TEST_IMAGE_SIGN)

# Without --allow-certificate-chain cosign silently falls back to the legacy
# path and reports "no signatures found". Asserted so we notice if that changes.
verify-expect-fail:
	@if $(COSIGN_BIN) verify \
		--trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--insecure-ignore-tlog --insecure-ignore-sct \
		$(TEST_IMAGE_SIGN) >/dev/null 2>&1; then \
		echo "[FAIL] verified without --allow-certificate-chain"; exit 1; \
	else \
		echo "[OK] failed without --allow-certificate-chain, as expected"; \
	fi

test: setup sign verify verify-expect-fail
	@echo "[OK] bundle verified: intermediate from bundle, root from trusted root"

# Path B: sign without cosign, asynchronously, then publish as an OCI referrer.
# sign-offline.sh runs openssl only; cosign is never invoked at signing time.
sign-offline:
	./sign-offline.sh $(TEST_IMAGE_SIGN)

# A fresh registry guarantees no cosign-made bundle is present, so a passing
# verify can only be explained by the hand-built bundle. Assert there is
# exactly one bundle referrer for the same reason.
v4-external-offline: setup-nokey sign-offline verify
	@n=$$(curl -s -H 'Accept: application/vnd.oci.image.index.v1+json' \
		http://$(TEST_REGISTRY)/v2/$(TEST_IMAGE)/manifests/$(subst :,-,$(TEST_DIGEST_LOCAL)) \
		| jq '[.manifests[] | select(.artifactType == "application/vnd.dev.sigstore.bundle.v0.3+json")] | length'); \
	if [ "$$n" != "1" ]; then echo "[FAIL] expected 1 bundle referrer, found $$n"; exit 1; fi
	@echo "[OK] cosign-free bundle verified: signed by openssl, published by oras"

clean:
	rm -rf $(EXAMPLES_DIR)
	docker rm -f $(TEST_REGISTRY_NAME) 2>/dev/null || true
