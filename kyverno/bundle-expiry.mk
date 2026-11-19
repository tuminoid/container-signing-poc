# Kyverno e2e for a timestamped bundle whose leaf has expired: cosign-v4-pre
# v4-leaf-expiry signs, waits until the leaf expires, and the image is
# admitted afterwards, the leaf checked at the signing time.

FLOW := bundle-expiry
SUITE := cosign-v4-pre
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5004
POLICIES := kyverno-policy-bundle.yaml
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/expiry-tsa:3.20.3

include common.mk

all: leaf-expired

sign:
	$(MAKE) -C $(COSIGN_DIR) clean v4-leaf-expiry

relocate:
	$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/expiry/tsa:3.20.3 \
		RELOCATE_REPO=$(TEST_REGISTRY)/$(firstword $(subst :, ,$(IMAGE_SIGNED)))

leaf-expired:
	@! openssl x509 -checkend 0 -noout -in $(COSIGN_DIR)/examples/expiry/leaf.crt >/dev/null || \
		{ echo "[FAIL] the signing leaf has not expired"; exit 1; }
	@echo "[OK] $(FLOW): admitted with the signing leaf expired"
