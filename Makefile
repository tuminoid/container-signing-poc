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

# For local-image-test: path to patched cosign source
COSIGN_SOURCE_DIR ?= $(HOME)/git/sigstore/cosign
COSIGN_PATCHED := cosign-patched

.PHONY: all notation cosign cosign-v2 cosign-v3 cosign-v4-pre clean local-image-test tripwire-cosign-main

all:
	@echo "targets: notation cosign cosign-v2 cosign-v3 cosign-v4-pre tripwire-cosign-main local-image-test clean"

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
# registries and installs the flow's Kyverno version.
# $(call kyverno-flow,flow file[,variables])
kyverno-flow = make -C $(KYVERNO_DIR) -f $(1) $(2)

cosign-v4-pre:
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
	make -C $(KYVERNO_DIR) api-versions

# Tripwire: cosign main at a pinned commit, built into build/cosign-main, has
# no attach signature command, and the legacy attach flow of cosign-v2 fails
# there for it. Refresh the pin to see whether that still holds.
COSIGN_MAIN_COMMIT := 0743bfcff5f81ec49ffcea2f61b98938f6ba70ec
COSIGN_MAIN_DIR := $(CURDIR)/build/cosign-main

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
	make -C $(COSIGN_V2_DIR) clean
	@echo "[OK] cosign main $(COSIGN_MAIN_COMMIT): the legacy attach flow fails, attach signature is gone"

local-image-test:
	@echo "==> Building patched cosign from $(COSIGN_SOURCE_DIR)..."
	@test -d "$(COSIGN_SOURCE_DIR)" || (echo "error: Cosign source not found at $(COSIGN_SOURCE_DIR). Set COSIGN_SOURCE_DIR." && exit 1)
	@test -f "$(COSIGN_SOURCE_DIR)/go.mod" || (echo "error: Invalid cosign source (no go.mod)" && exit 1)
	cd $(COSIGN_SOURCE_DIR) && go build -o $(CURDIR)/$(COSIGN_PATCHED) ./cmd/cosign
	@test -f $(COSIGN_PATCHED) || (echo "error: Build failed" && exit 1)
	@echo "==> Testing cosign-v2 local image verification..."
	$(MAKE) -C $(COSIGN_V2_DIR) e2e-local COSIGN_BIN=$(CURDIR)/$(COSIGN_PATCHED) || (rm -f $(COSIGN_PATCHED) && exit 1)
	@echo "==> Testing cosign-v3 local image verification..."
	$(MAKE) -C $(COSIGN_V3_DIR) e2e-local COSIGN_BIN=$(CURDIR)/$(COSIGN_PATCHED) || (rm -f $(COSIGN_PATCHED) && exit 1)
	@echo "==> Testing cosign-v3 native signing + local image verification..."
	$(MAKE) -C $(COSIGN_V3_DIR) test-local-image COSIGN_BIN=$(CURDIR)/$(COSIGN_PATCHED) || (rm -f $(COSIGN_PATCHED) && exit 1)
	rm -f $(COSIGN_PATCHED)
	@echo "[OK] All local image verification tests passed"

clean:
	make -C $(NOTATION_DIR) clean
	make -C $(ORAS_DIR) clean
	make -C $(COSIGN_V2_DIR) clean
	make -C $(COSIGN_V3_DIR) clean
	make -C $(COSIGN_V4_PRE_DIR) clean
	make -C $(KYVERNO_DIR) clean
	rm -f $(COSIGN_PATCHED)
	rm -rf build/cosign-main
