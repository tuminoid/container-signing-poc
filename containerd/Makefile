# Containerd + Transfer Service Signature Verification POC (BYO-PKI)

SHELL := /bin/bash
TEST_REGISTRY_PRIMARY := 127.0.0.1:5000
TEST_REGISTRY_SECONDARY := 127.0.0.1:5001
# Sigstore bundles (cosign v4 format) as OCI referrers, verified via a trusted root
TEST_REGISTRY_BUNDLE := 127.0.0.1:5002
TEST_IMAGE := alpine:3.20.3
EXAMPLES_DIR := examples
CERT_SCRIPT := ./scripts/gencrt.sh

.PHONY: help setup run test test-v2 clean status check-vm gen-certs push-unsigned-test sign-image sign-image-v2 sign-image-bundle sign-image-v4 setup-registry install-hooks verify

help:
	@echo "Containerd Transfer Service BYO-PKI Signature Verification"
	@echo ""
	@echo "Usage:"
	@echo "  make setup       # Install containerd 2.1+, k8s, docker, cosign (requires reboot)"
	@echo "  make run         # Install verifier, init k8s, sign images, run tests"
	@echo "  make test-v2     # Test v2 attached signatures"
	@echo "  make clean       # Reset everything"
	@echo ""
	@echo "Requires: containerd 2.1+ for Transfer Service API"
	@echo "See: https://github.com/containerd/containerd/blob/main/docs/transfer.md"

setup:
	@echo "==> Running one-time setup (requires root)..."
	@sudo ./scripts/setup-vm.sh
	@echo ""
	@echo "========================================"
	@echo "Setup complete! REBOOT REQUIRED."
	@echo "========================================"
	@echo "After reboot, run: make run"

check-vm:
	@if ! command -v containerd >/dev/null 2>&1; then \
		echo "ERROR: containerd not installed. Run: make setup"; \
		exit 1; \
	fi
	@if ! systemctl is-active --quiet containerd; then \
		echo "ERROR: containerd not running."; \
		exit 1; \
	fi

setup-registry:
	@echo "==> Starting test registries..."
	@# Primary registry (port 5000) - requires verification
	@if docker ps --format '{{.Names}}' | grep -q "^containerd-registry-primary$$"; then \
		echo "Primary registry already running"; \
	else \
		docker run -d --restart=always -p $(TEST_REGISTRY_PRIMARY):5000 --name containerd-registry-primary registry:2 >/dev/null 2>&1; \
		sleep 2; \
		echo "OK: Primary registry started ($(TEST_REGISTRY_PRIMARY))"; \
	fi
	@# Secondary registry (port 5001) - no verification
	@if docker ps --format '{{.Names}}' | grep -q "^containerd-registry-secondary$$"; then \
		echo "Secondary registry already running"; \
	else \
		docker run -d --restart=always -p $(TEST_REGISTRY_SECONDARY):5000 --name containerd-registry-secondary registry:2 >/dev/null 2>&1; \
		sleep 2; \
		echo "OK: Secondary registry started ($(TEST_REGISTRY_SECONDARY))"; \
	fi
	@# Bundle registry (port 5002) - requires verification against a trusted root
	@if docker ps --format '{{.Names}}' | grep -q "^containerd-registry-bundle$$"; then \
		echo "Bundle registry already running"; \
	else \
		docker run -d --restart=always -p $(TEST_REGISTRY_BUNDLE):5000 --name containerd-registry-bundle registry:3 >/dev/null 2>&1; \
		sleep 2; \
		echo "OK: Bundle registry started ($(TEST_REGISTRY_BUNDLE))"; \
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

sign-image: sign-image-v2 sign-image-bundle
	@echo "Images signed"

sign-image-v2: setup-registry gen-certs
	@# Sign image for primary registry with v2 (attach signature)
	@echo "==> Signing $(TEST_IMAGE) with cosign v2 (attach signature)..."
	@if cosign verify \
		--new-bundle-format=false \
		--ca-roots=$(EXAMPLES_DIR)/ca.crt \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--private-infrastructure \
		--insecure-ignore-sct \
		--allow-insecure-registry \
		$(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE) >/dev/null 2>&1; then \
		echo "Primary registry image (v2) already signed"; \
	else \
		docker pull $(TEST_IMAGE) >/dev/null 2>&1; \
		docker tag $(TEST_IMAGE) $(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE) 2>/dev/null; \
		docker push $(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE) >/dev/null 2>&1; \
		\
		TAG=$$(echo $(TEST_IMAGE) | cut -d: -f2); \
		\
		: 'Get digest from registry API, not docker inspect'; \
		: 'docker inspect returns local cache digest, not manifest digest'; \
		IMAGE_DIGEST=$$(curl -s -I http://$(TEST_REGISTRY_PRIMARY)/v2/alpine/manifests/$$TAG -H 'Accept: application/vnd.oci.image.manifest.v1+json' | grep -i docker-content-digest | cut -d' ' -f2 | tr -d '\r'); \
		IMAGE_REF="$(TEST_REGISTRY_PRIMARY)/alpine@$$IMAGE_DIGEST"; \
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
		echo "OK: Image signed with cosign v2 (attach signature)"; \
	fi

# Bundle as cosign v4 produces it: leaf plus intermediate in the bundle, root
# in the trusted root, no transparency log. alpine:unsigned is the negative.
sign-image-bundle: setup-registry gen-certs
	@echo "==> Signing $(TEST_IMAGE) into a Sigstore bundle..."
	docker pull -q $(TEST_IMAGE) >/dev/null
	docker tag $(TEST_IMAGE) $(TEST_REGISTRY_BUNDLE)/$(TEST_IMAGE)
	docker push -q $(TEST_REGISTRY_BUNDLE)/$(TEST_IMAGE) >/dev/null
	docker pull -q alpine:3.19 >/dev/null
	docker tag alpine:3.19 $(TEST_REGISTRY_BUNDLE)/alpine:unsigned
	docker push -q $(TEST_REGISTRY_BUNDLE)/alpine:unsigned >/dev/null
	cosign trusted-root create \
		--fulcio="url=https://private.local,certificate-chain=$(EXAMPLES_DIR)/ca.crt" \
		--out=$(EXAMPLES_DIR)/trusted-root.json
	cosign signing-config create --out=$(EXAMPLES_DIR)/signing-config.tmp
	jq 'del(.rekorTlogUrls)' $(EXAMPLES_DIR)/signing-config.tmp > $(EXAMPLES_DIR)/signing-config.json
	test -f $(EXAMPLES_DIR)/leaf-imported.key || COSIGN_PASSWORD= cosign import-key-pair \
		--key $(EXAMPLES_DIR)/leaf.key --output-key-prefix $(EXAMPLES_DIR)/leaf-imported
	@DIGEST=$$(curl -s -I http://$(TEST_REGISTRY_BUNDLE)/v2/alpine/manifests/$(lastword $(subst :, ,$(TEST_IMAGE))) \
		-H 'Accept: application/vnd.oci.image.manifest.v1+json' | grep -i docker-content-digest | cut -d' ' -f2 | tr -d '\r'); \
	COSIGN_PASSWORD= cosign sign \
		--key=$(EXAMPLES_DIR)/leaf-imported.key \
		--certificate=$(EXAMPLES_DIR)/leaf.crt \
		--certificate-chain=$(EXAMPLES_DIR)/sub-ca.crt \
		--signing-config=$(EXAMPLES_DIR)/signing-config.json \
		--trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		--yes $(TEST_REGISTRY_BUNDLE)/alpine@$$DIGEST && \
	cosign verify --allow-certificate-chain --trusted-root=$(EXAMPLES_DIR)/trusted-root.json \
		--certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' \
		--insecure-ignore-tlog --insecure-ignore-sct $(TEST_REGISTRY_BUNDLE)/alpine@$$DIGEST >/dev/null
	@echo "OK: Image signed into a bundle and verified"

install-hooks:
	@if [[ ! -f "$(EXAMPLES_DIR)/ca.crt" ]]; then \
		echo "ERROR: CA certificate not found. Run 'make gen-certs' first."; \
		exit 1; \
	fi
	@echo "==> Installing Transfer Service Image Verifier (requires root)..."
	@sudo ./scripts/install-transfer-verifier.sh

# The production shape on 127.0.0.1:5004, signed without cosign by
# ../cosign-v4-pre: RSA 4096 leaf, leaf-only bundle, signed timestamp, CA chain
# and TSA in the trusted root, plus the multi-arch images, and then, with the
# same PKI and TSA, the timestamped bundle of a leaf that has expired once
# v4-leaf-expiry returns. Its registry and TSA start afresh, so this runs, and
# the verifier is reinstalled, on every test.
sign-image-v4:
	$(MAKE) -C ../cosign-v4-pre clean v4-multiarch
	$(MAKE) -C ../cosign-v4-pre v4-leaf-expiry -o setup-nokey -o trusted-root-tsa

verify:
	@echo "==> Verifying signed image with BYO-PKI certificates..."
	@cosign verify \
		--new-bundle-format=false \
		--ca-roots=$(EXAMPLES_DIR)/ca.crt \
		--certificate-identity-regexp '.*' \
		--certificate-oidc-issuer-regexp '.*' \
		--private-infrastructure \
		--insecure-ignore-sct \
		--allow-insecure-registry \
		$(TEST_REGISTRY_PRIMARY)/$(TEST_IMAGE)
	@echo ""
	@echo "[OK] Signature verification successful!"

run: check-vm
	@if [[ ! -f "$(EXAMPLES_DIR)/leaf.key" ]]; then \
		echo "==> Setting up registry and signing images (first run)..."; \
		$(MAKE) setup-registry gen-certs sign-image; \
		echo ""; \
	fi
	$(MAKE) push-unsigned-test sign-image-v4 install-hooks
	@if ! kubectl get nodes &> /dev/null; then \
		echo "==> Initializing Kubernetes cluster (first run)..."; \
		sudo ./scripts/init-k8s.sh; \
		echo ""; \
	fi
	@./scripts/test-verification.sh

test: run

test-v2:
	@echo "==> Testing v2 signature verification..."
	@$(MAKE) push-unsigned-test sign-image-v2
	@./scripts/test-verification.sh

status:
	@echo "Status:"
	@docker ps --format '{{.Names}}' | grep -q "^containerd-registry-primary$$" && echo "  OK: Primary registry running ($(TEST_REGISTRY_PRIMARY))" || echo "  ERROR: Primary registry not running"
	@docker ps --format '{{.Names}}' | grep -q "^containerd-registry-secondary$$" && echo "  OK: Secondary registry running ($(TEST_REGISTRY_SECONDARY))" || echo "  ERROR: Secondary registry not running"
	@[[ -f $(EXAMPLES_DIR)/leaf.key ]] && echo "  OK: Certificates exist" || echo "  ERROR: Certificates missing"
	@[[ -x /opt/containerd/image-verifier/bin/verifier ]] && echo "  OK: Verifier installed" || echo "  ERROR: Verifier missing"
	@[[ -f /etc/containerd/certs/registry-primary-ca.crt ]] && echo "  OK: CA certificate installed" || echo "  ERROR: CA certificate missing"
	@systemctl is-active --quiet containerd && echo "  OK: containerd running" || echo "  ERROR: containerd not running"

clean:
	@echo "Cleaning test artifacts and hooks..."
	@echo "==> Resetting Kubernetes cluster..."
	-@sudo kubeadm reset -f 2>/dev/null || true
	@rm -f /tmp/containerd-test-*.log /tmp/pod-*.yaml
	@echo "==> Removing hooks and certificates (requires sudo)..."
	@sudo ./scripts/clean-all.sh
	@echo "==> Removing registries and local certificates..."
	-@docker rm -f containerd-registry-primary containerd-registry-secondary \
		containerd-registry-bundle 2>/dev/null || true
	$(MAKE) -C ../cosign-v4-pre clean
	@rm -rf $(EXAMPLES_DIR)
	@echo "OK: Clean complete"
