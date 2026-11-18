# Kyverno e2e for development signatures, option 3 of cosign-v4-pre
# v4-dev-signatures: the image travels with a development and a production
# bundle, and the policy trusts the production root alone. The same image with
# only the development bundle is denied.

FLOW := bundle-dev
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5004
POLICY := kyverno-policy-bundle.yaml
POLICY_NAME := check-image-bundle
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/dev-prod:3.20.3

include common.mk

all: dev-only-denied

sign:
	$(MAKE) -C $(COSIGN_DIR) clean v4-dev-signatures

relocate:
	$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/dev/alpine:3.20.3 \
		RELOCATE_REPO=$(TEST_REGISTRY)/bundle/dev-prod
	$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/dev-only/alpine:3.20.3 \
		RELOCATE_REPO=$(TEST_REGISTRY)/bundle/dev-only

dev-only-denied:
	$(call denied,pod-dev-only,bundle/dev-only:3.20.3,failed to verify leaf certificate)
	@echo "[OK] $(FLOW): admitted on the production bundle alone"
