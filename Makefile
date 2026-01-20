# top level makefile to run e2e test
# 1st flow: notation -> oras copy -> kyverno
# 2nd flow: cosign-v2 -> kyverno
# 3rd flow: cosign-v3 -> kyverno
# kyverno tests both cosign and notation

NOTATION_DIR := notation
ORAS_DIR := oras
KYVERNO_DIR := kyverno
COSIGN_V2_DIR := cosign-v2
COSIGN_V3_DIR := cosign-v3

SHELL := /bin/bash

# For local-image-test: path to patched cosign source
COSIGN_SOURCE_DIR ?= $(HOME)/git/sigstore/cosign
COSIGN_PATCHED := cosign-patched

.PHONY: all notation cosign cosign-v2 cosign-v3 clean local-image-test

all:
	@echo "targets: notation cosign cosign-v2 cosign-v3 local-image-test clean"

notation:
	make -C $(KYVERNO_DIR) setup
	make -C $(KYVERNO_DIR) -f notation.mk

cosign-v2:
	make -C $(KYVERNO_DIR) setup
	make -C $(KYVERNO_DIR) -f cosign-v2.mk

cosign-v3:
	make -C $(KYVERNO_DIR) setup
	make -C $(KYVERNO_DIR) -f cosign-v3.mk

cosign: cosign-v2 cosign-v3
	@echo "Both cosign v2 and v3 tests completed"

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
	make -C $(KYVERNO_DIR) clean
	rm -f $(COSIGN_PATCHED)
