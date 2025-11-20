# CRI-O Signature Verification POC (BYO-PKI)

SHELL := /bin/bash
TEST_REGISTRY_PRIMARY := 127.0.0.1:5003
TEST_REGISTRY_SECONDARY := 127.0.0.1:5002
TEST_IMAGE := alpine:3.20.3
EXAMPLES_DIR := examples
CERT_SCRIPT := ./scripts/gencrt.sh

.PHONY: help setup run test clean status check-vm gen-certs sign-image setup-registry install-policy verify

help:
	@echo "CRI-O BYO-PKI Signature Verification"
	@echo ""
	@echo "Usage:"
	@echo "  make setup    # Install CRI-O 1.34+, k8s, docker, cosign (requires reboot)"
	@echo "  make run      # Auto-init k8s, sign images, run tests"
	@echo "  make clean    # Reset everything"
	@echo ""
	@echo "Requires: CRI-O 1.34+ (containers/image v5.34.1+ for pki field)"
	@echo "See: https://github.com/containers/image/pull/2557"

setup:
	@echo "==> Running one-time setup (requires root)..."
	@sudo ./scripts/setup-vm.sh
	@echo ""
	@echo "========================================"
	@echo "Setup complete! REBOOT REQUIRED."
	@echo "========================================"
	@echo "After reboot, run: make run"

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
	@echo "==> Starting test registries..."
	@# Primary registry (port 5003) - requires signature verification
	@if docker ps --format '{{.Names}}' | grep -q "^crio-registry-primary$$"; then \
		echo "Primary registry already running"; \
	else \
		docker run -d --restart=always -p $(TEST_REGISTRY_PRIMARY):5000 --name crio-registry-primary registry:2 >/dev/null 2>&1; \
		sleep 2; \
		echo "OK: Primary registry started ($(TEST_REGISTRY_PRIMARY))"; \
	fi
	@# Secondary registry (port 5002) - no verification required
	@if docker ps --format '{{.Names}}' | grep -q "^crio-registry-secondary$$"; then \
		echo "Secondary registry already running"; \
	else \
		docker run -d --restart=always -p $(TEST_REGISTRY_SECONDARY):5000 --name crio-registry-secondary registry:2 >/dev/null 2>&1; \
		sleep 2; \
		echo "OK: Secondary registry started ($(TEST_REGISTRY_SECONDARY))"; \
	fi

gen-certs:
	@mkdir -p $(EXAMPLES_DIR)
	@if [[ -f $(EXAMPLES_DIR)/leaf.key ]] && [[ -f $(EXAMPLES_DIR)/leaf.crt ]]; then \
		echo "Certificates already exist"; \
	else \
		rm -f $(EXAMPLES_DIR)/*.crt $(EXAMPLES_DIR)/*.key $(EXAMPLES_DIR)/*.pem $(EXAMPLES_DIR)/*.csr $(EXAMPLES_DIR)/*.conf $(EXAMPLES_DIR)/index* $(EXAMPLES_DIR)/serial*; \
		$(CERT_SCRIPT); \
	fi

push-unsigned-test: setup-registry
	@# Push unsigned image to primary registry (should be rejected)
	@echo "==> Pushing unsigned test image to primary registry..."
	@docker pull alpine:3.19 >/dev/null 2>&1
	@docker tag alpine:3.19 $(TEST_REGISTRY_PRIMARY)/alpine:unsigned
	@docker push $(TEST_REGISTRY_PRIMARY)/alpine:unsigned >/dev/null 2>&1
	@echo "OK: Unsigned test image pushed to primary registry"
	@# Push test image to secondary registry (should be allowed)
	@echo "==> Pushing test image to secondary registry..."
	@docker pull nginx:alpine >/dev/null 2>&1
	@docker tag nginx:alpine $(TEST_REGISTRY_SECONDARY)/nginx:alpine
	@docker push $(TEST_REGISTRY_SECONDARY)/nginx:alpine >/dev/null 2>&1
	@echo "OK: Test image pushed to secondary registry"

sign-image: setup-registry gen-certs push-unsigned-test
	@# Check if already signed
	@if cosign verify \
		--certificate-chain $(EXAMPLES_DIR)/certificate_chain.pem \
		--certificate-identity-regexp '.*ci-build@example.com' \
		--certificate-oidc-issuer-regexp '.*' \
		--insecure-ignore-tlog \
		--insecure-ignore-sct \
		--allow-insecure-registry \
		$(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE) >/dev/null 2>&1; then \
		echo "Image already signed"; \
	else \
		docker pull $(TEST_IMAGE) >/dev/null 2>&1; \
		docker tag $(TEST_IMAGE) $(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE) 2>/dev/null; \
		docker push $(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE) >/dev/null 2>&1; \
		\
		TAG=$$(echo $(TEST_IMAGE) | cut -d: -f2); \
		IMAGE_NAME=$$(echo $(TEST_IMAGE) | cut -d: -f1); \
		\
		: 'Get digest from registry API, not docker inspect'; \
		: 'docker inspect returns local cache digest, not manifest digest'; \
		: 'See https://github.com/sigstore/cosign/blob/main/USAGE.md#sign-a-container-and-store-its-signature-in-the-registry'; \
		IMAGE_DIGEST=$$(curl -s -I http://$(TEST_REGISTRY_PRIMARY)/v2/$$IMAGE_NAME/manifests/$$TAG -H 'Accept: application/vnd.oci.image.manifest.v1+json' | grep -i docker-content-digest | cut -d' ' -f2 | tr -d '\r'); \
		IMAGE_REF="$(TEST_REGISTRY_PRIMARY)/$$IMAGE_NAME@$$IMAGE_DIGEST"; \
		\
		cosign generate "$$IMAGE_REF" > $(EXAMPLES_DIR)/payload.json; \
		openssl dgst -sha256 -sign $(EXAMPLES_DIR)/leaf.key \
			-out $(EXAMPLES_DIR)/payload.sig $(EXAMPLES_DIR)/payload.json; \
		base64 $(EXAMPLES_DIR)/payload.sig > $(EXAMPLES_DIR)/payloadbase64.sig; \
		\
		cosign attach signature \
			--payload $(EXAMPLES_DIR)/payload.json \
			--signature $(EXAMPLES_DIR)/payloadbase64.sig \
			--certificate $(EXAMPLES_DIR)/leaf.crt \
			--certificate-chain $(EXAMPLES_DIR)/certificate_chain.pem \
			"$$IMAGE_REF"; \
		\
		echo "OK: Image signed with BYO-PKI certificate ($$IMAGE_REF)"; \
	fi

install-policy:
	@echo "==> Installing policy (requires root)..."
	@sudo ./scripts/install-policy.sh

verify:
	@echo "==> Verifying signed image with BYO-PKI certificates..."
	@cosign verify \
		--certificate-chain $(EXAMPLES_DIR)/certificate_chain.pem \
		--certificate-identity-regexp '.*ci-build@example.com' \
		--certificate-oidc-issuer-regexp '.*' \
		--insecure-ignore-tlog \
		--insecure-ignore-sct \
		--allow-insecure-registry \
		$(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE)
	@echo ""
	@echo "✅ Signature verification successful!"

run: check-vm
	@if ! kubectl get nodes &> /dev/null 2>&1; then \
		echo "==> Kubernetes not initialized, setting up cluster..."; \
		echo "   This will take a few minutes on first run..."; \
		sudo ./scripts/init-k8s.sh; \
		echo ""; \
	fi
	@if [[ ! -f "$(EXAMPLES_DIR)/leaf.key" ]]; then \
		echo "==> Setting up registry and signing images (first run)..."; \
		$(MAKE) setup-registry gen-certs sign-image; \
		echo ""; \
	fi
	@if [[ ! -f /etc/containers/certs/ca-roots.pem ]]; then \
		$(MAKE) install-policy; \
		echo ""; \
	fi
	@./scripts/test-verification.sh

test: run

status:
	@echo "Status:"
	@docker ps --format '{{.Names}}' | grep -q "^crio-registry-primary$$" && echo "  OK: Primary registry running ($(TEST_REGISTRY_PRIMARY))" || echo "  ERROR: Primary registry not running"
	@docker ps --format '{{.Names}}' | grep -q "^crio-registry-secondary$$" && echo "  OK: Secondary registry running ($(TEST_REGISTRY_SECONDARY))" || echo "  ERROR: Secondary registry not running"
	@[[ -f $(EXAMPLES_DIR)/leaf.key ]] && echo "  OK: Certificates exist" || echo "  ERROR: Certificates missing"
	@[[ -f /etc/crio/policy.json ]] && echo "  OK: Policy installed" || echo "  ERROR: Policy missing"
	@[[ -f /etc/containers/certs/ca-roots.pem ]] && echo "  OK: CA certificates installed" || echo "  ERROR: CA certificates missing"
	@systemctl is-active --quiet crio && echo "  OK: CRI-O running" || echo "  ERROR: CRI-O not running"

clean:
	@echo "Cleaning test artifacts and policy..."
	@echo "==> Resetting Kubernetes cluster..."
	-@sudo kubeadm reset -f 2>/dev/null || true
	-@kubectl delete pod signed-alpine-crio unsigned-alpine-crio secondary-nginx-crio --wait=false 2>/dev/null || true
	-@sudo crictl rmi --prune 2>/dev/null || true
	@rm -f /tmp/crio-test-*.log
	@echo "==> Removing policy and certificates (requires sudo)..."
	@sudo ./scripts/clean-all.sh
	@echo "==> Removing registries and local certificates..."
	-@docker stop crio-registry-primary 2>/dev/null || true
	-@docker rm crio-registry-primary 2>/dev/null || true
	-@docker stop crio-registry-secondary 2>/dev/null || true
	-@docker rm crio-registry-secondary 2>/dev/null || true
	@rm -rf $(EXAMPLES_DIR)
	@echo "OK: Clean complete"
