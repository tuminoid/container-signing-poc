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

.PHONY: all notation cosign cosign-v2 cosign-v3 clean

all:
	@echo "targets: notation cosign cosign-v2 cosign-v3 clean"

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

clean:
	make -C $(NOTATION_DIR) clean
	make -C $(ORAS_DIR) clean
	make -C $(COSIGN_V2_DIR) clean
	make -C $(COSIGN_V3_DIR) clean
	make -C $(KYVERNO_DIR) clean
