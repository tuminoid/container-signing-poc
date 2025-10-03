# CRI-O Signature Verification POC

SHELL := /bin/bash
TEST_REGISTRY := 127.0.0.1:5003
TEST_IMAGE := alpine:3.20.3
EXAMPLES_DIR := examples

.PHONY: help setup all test clean clean-all status

help:
	@echo "CRI-O Signature Verification POC"
	@echo ""
	@echo "Quick start (Ubuntu 24.04 VM):"
	@echo "  make setup        # One-time setup (requires sudo, requires reboot)"
	@echo "  <reboot>"
	@echo "  make test         # Run tests"
	@echo "  make clean        # Clean test artifacts"
	@echo ""
	@echo "Full cleanup:"
	@echo "  make clean-all    # Remove everything"

setup:
	@echo "==> Running one-time setup (requires root)..."
	@sudo ./scripts/setup-vm.sh
	@echo ""
	@echo "========================================"
	@echo "Setup complete! REBOOT REQUIRED."
	@echo "========================================"
	@echo "After reboot, run: make test"

all: setup

check-vm:
	@if ! command -v crio >/dev/null 2>&1; then \
		echo "ERROR: CRI-O not installed. Run: make setup"; \
		exit 1; \
	fi
	@if ! systemctl is-active --quiet crio; then \
		echo "ERROR: CRI-O not running."; \
		exit 1; \
	fi

setup-registry:
	@if docker ps --format '{{.Names}}' | grep -q "^crio-registry$$"; then \
		echo "Registry already running"; \
	else \
		docker run -d --restart=always -p $(TEST_REGISTRY):5000 --name crio-registry registry:2 >/dev/null 2>&1; \
		sleep 2; \
		echo "OK: Registry started"; \
	fi

gen-keys:
	@mkdir -p $(EXAMPLES_DIR)
	@if [[ -f $(EXAMPLES_DIR)/cosign.key ]] && [[ -f $(EXAMPLES_DIR)/cosign.pub ]]; then \
		echo "Keys already exist"; \
	else \
		rm -f $(EXAMPLES_DIR)/cosign.key $(EXAMPLES_DIR)/cosign.pub; \
		COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix=$(EXAMPLES_DIR)/cosign 2>/dev/null; \
		echo "OK: Keys generated"; \
	fi

sign-image: setup-registry gen-keys
	@if cosign verify --key $(EXAMPLES_DIR)/cosign.pub --insecure-ignore-tlog --allow-insecure-registry $(TEST_REGISTRY)/$(TEST_IMAGE) >/dev/null 2>&1; then \
		echo "Image already signed"; \
	else \
		docker pull $(TEST_IMAGE) >/dev/null 2>&1; \
		docker tag $(TEST_IMAGE) $(TEST_REGISTRY)/$(TEST_IMAGE) 2>/dev/null; \
		docker push $(TEST_REGISTRY)/$(TEST_IMAGE) >/dev/null 2>&1; \
		COSIGN_PASSWORD="" cosign sign --key $(EXAMPLES_DIR)/cosign.key --tlog-upload=false --allow-insecure-registry --yes $(TEST_REGISTRY)/$(TEST_IMAGE) >/dev/null 2>&1; \
		echo "OK: Image signed"; \
	fi

test: check-vm
	@if [[ ! -f "$(EXAMPLES_DIR)/cosign.key" ]]; then \
		echo "==> Setting up registry and signing images (first run)..."; \
		$(MAKE) setup-registry gen-keys sign-image; \
		echo ""; \
	fi
	@if [[ ! -f /etc/containers/policy.json ]]; then \
		echo "==> Installing policy (first run, requires root)..."; \
		sudo ./scripts/install-policy.sh; \
		echo ""; \
	fi
	@./scripts/test-verification.sh

status:
	@echo "Status:"
	@docker ps --format '{{.Names}}' | grep -q "^crio-registry$$" && echo "  OK: Registry running" || echo "  ERROR: Registry not running"
	@[[ -f $(EXAMPLES_DIR)/cosign.key ]] && echo "  OK: Keys exist" || echo "  ERROR: Keys missing"
	@[[ -f /etc/containers/policy.json ]] && echo "  OK: Policy installed" || echo "  ERROR: Policy missing"
	@systemctl is-active --quiet crio && echo "  OK: CRI-O running" || echo "  ERROR: CRI-O not running"

clean:
	@echo "Cleaning test artifacts..."
	-@sudo crictl rmi 127.0.0.1:5003/alpine:3.20.3 2>/dev/null || true
	-@sudo crictl rmi alpine:latest 2>/dev/null || true
	@rm -f /tmp/crio-test-*.log
	@echo "OK: Test artifacts cleaned"

clean-all:
	@echo "==> Removing policy and keys..."
	@sudo ./scripts/clean-all.sh
	@echo "==> Removing registry and local keys..."
	-@docker stop crio-registry 2>/dev/null || true
	-@docker rm crio-registry 2>/dev/null || true
	@rm -rf $(EXAMPLES_DIR)
	@echo "OK: Full cleanup complete"
