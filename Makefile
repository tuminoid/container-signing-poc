# Top-level e2e flows: sign, relocate, admit with Kyverno.
# notation: notation -> oras -> kyverno 1.20 ImageValidatingPolicy
# cosign-v2: cosign legacy signatures -> cosign save/load -> kyverno 1.19
#   ClusterPolicy
# cosign-v3: same signatures -> kyverno 1.19 ClusterPolicy, ImageValidatingPolicy
#   and both together
# cosign-v4-pre: sigstore bundles -> oras -> kyverno 1.20 ImageValidatingPolicy

NOTATION_DIR := notation
ORAS_DIR := oras
KYVERNO_DIR := kyverno
COSIGN_V2_DIR := cosign-v2
COSIGN_V3_DIR := cosign-v3
COSIGN_V4_PRE_DIR := cosign-v4-pre

SHELL := /bin/bash

.PHONY: all notation cosign cosign-v2 cosign-v3 cosign-v4-pre clean tripwire-cosign-main

all:
	@echo "targets: notation cosign cosign-v2 cosign-v3 cosign-v4-pre tripwire-cosign-main clean"

notation:
	make -C $(KYVERNO_DIR) -f notation.mk

cosign-v2:
	make -C $(KYVERNO_DIR) -f cosign-v2.mk

cosign-v3:
	make -C $(KYVERNO_DIR) -f cosign-v3.mk

cosign: cosign-v2 cosign-v3
	@echo "Both cosign v2 and v3 tests completed"

# Sigstore bundles only, anticipating cosign v4: the standalone signing flows,
# then the Kyverno flows, which run the remaining cosign-v4-pre targets as
# their signing step. Separate make runs, as each flow starts from fresh
# registries and certificates; each Kyverno flow runs setup, which empties the
# registries and installs the flow's Kyverno version. DEVCERTS, the extracted
# EPPKI C1 dev kit, adds its flow.
# $(call kyverno-flow,flow file[,variables])
kyverno-flow = make -C $(KYVERNO_DIR) -f $(1) $(2)

cosign-v4-pre:
	$(if $(DEVCERTS),make -C $(COSIGN_V4_PRE_DIR) devkit-check)
	make -C $(COSIGN_V4_PRE_DIR) test
	make -C $(COSIGN_V4_PRE_DIR) v4-external-plugin
	make -C $(COSIGN_V4_PRE_DIR) v4-external-offline
	make -C $(COSIGN_V4_PRE_DIR) v4-relocate
	make -C $(COSIGN_V4_PRE_DIR) v4-external-offline-tsa
	make -C $(COSIGN_V4_PRE_DIR) v4-san-required
	make -C $(COSIGN_V4_PRE_DIR) v4-save-load
	make -C $(COSIGN_V4_PRE_DIR) v4-rotation
	make -C $(COSIGN_V4_PRE_DIR) v4-tls
	$(call kyverno-flow,cosign-v4-pre.mk)
	$(call kyverno-flow,cosign-v4-pre.mk,SIGN_TARGET=v4-rsa)
	$(call kyverno-flow,cosign-v4-pre.mk,DIGEST=false)
	$(call kyverno-flow,bundle-dev.mk)
	$(call kyverno-flow,bundle-zot.mk)
	$(call kyverno-flow,bundle-shapes.mk)
	$(call kyverno-flow,bundle-multiarch.mk)
	$(call kyverno-flow,bundle-expiry.mk)
	$(call kyverno-flow,bundle-binding.mk)
	$(if $(DEVCERTS),$(call kyverno-flow,bundle-devcerts.mk))
	make -C $(KYVERNO_DIR) api-versions

# Tripwire: cosign main at a pinned commit, built into build/cosign-main, has
# no attach signature command, and the legacy attach flow of cosign-v2 fails
# there for it. A legacy signature attached by the installed cosign does not
# verify there either: --ca-roots is gone, and with a trusted root cosign main
# looks for bundles only, where the installed cosign 3.x, given the same bundle
# flags, falls back to the legacy signature and verifies it. Refresh the pin
# to see whether that still holds.
COSIGN_MAIN_COMMIT := ab26c80dd5737351ebdeda7e52ba1f568b26938e
COSIGN_MAIN_DIR := $(CURDIR)/build/cosign-main
# The image cosign-v2 signs, pinned there
LEGACY_REF := 127.0.0.1:5003/alpine@$(shell sed -n 's/^TEST_DIGEST_LOCAL := //p' $(COSIGN_V2_DIR)/Makefile)
# $(call bundle-verify,cosign): verification of a bundle against the CA chain
bundle-verify = $(1) verify --trusted-root=$(COSIGN_MAIN_DIR)/trusted-root.json --allow-certificate-chain \
	--certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' \
	--insecure-ignore-tlog --insecure-ignore-sct $(LEGACY_REF)

tripwire-cosign-main:
	GOBIN=$(COSIGN_MAIN_DIR) go install github.com/sigstore/cosign/v3/cmd/cosign@$(COSIGN_MAIN_COMMIT)
	@$(COSIGN_MAIN_DIR)/cosign attach --help 2>&1 | grep -q '^bundle ' && \
		! $(COSIGN_MAIN_DIR)/cosign attach --help 2>&1 | grep -q '^signature ' || \
		{ echo "[FAIL] cosign main attach commands changed"; exit 1; }
	@if make -C $(COSIGN_V2_DIR) test COSIGN_BIN=$(COSIGN_MAIN_DIR)/cosign \
		> $(COSIGN_MAIN_DIR)/legacy.log 2>&1; then \
		echo "[FAIL] the legacy attach flow passes on cosign main"; exit 1; fi
	@grep -q 'unknown flag: --payload' $(COSIGN_MAIN_DIR)/legacy.log || \
		{ echo "[FAIL] unexpected failure, see $(COSIGN_MAIN_DIR)/legacy.log"; exit 1; }
	make -C $(COSIGN_V2_DIR) clean test
	@if make -C $(COSIGN_V2_DIR) verify COSIGN_BIN=$(COSIGN_MAIN_DIR)/cosign \
		> $(COSIGN_MAIN_DIR)/legacy-verify.log 2>&1; then \
		echo "[FAIL] legacy verification passes on cosign main"; exit 1; fi
	@grep -q 'unknown flag: --ca-roots' $(COSIGN_MAIN_DIR)/legacy-verify.log || \
		{ echo "[FAIL] unexpected failure, see $(COSIGN_MAIN_DIR)/legacy-verify.log"; exit 1; }
	cat $(COSIGN_V2_DIR)/examples/sub-ca.crt $(COSIGN_V2_DIR)/examples/ca.crt > $(COSIGN_MAIN_DIR)/ca-chain.pem
	cosign trusted-root create --out=$(COSIGN_MAIN_DIR)/trusted-root.json \
		--fulcio="url=https://private.local,certificate-chain=$(COSIGN_MAIN_DIR)/ca-chain.pem"
	$(call bundle-verify,cosign) >/dev/null
	@if out=$$($(call bundle-verify,$(COSIGN_MAIN_DIR)/cosign) 2>&1); then \
		echo "[FAIL] cosign main verifies a legacy signature against a trusted root"; exit 1; fi; \
	grep -q 'no valid bundles exist in registry' <<< "$$out" || \
		{ echo "[FAIL] unexpected failure: $$out"; exit 1; }
	make -C $(COSIGN_V2_DIR) clean
	@echo "[OK] cosign main $(COSIGN_MAIN_COMMIT): legacy attach and legacy verification are gone, cosign 3.x falls back to legacy"

clean:
	make -C $(NOTATION_DIR) clean
	make -C $(ORAS_DIR) clean
	make -C $(COSIGN_V2_DIR) clean
	make -C $(COSIGN_V3_DIR) clean
	make -C $(COSIGN_V4_PRE_DIR) clean
	make -C $(KYVERNO_DIR) clean
	rm -rf build/cosign-main
