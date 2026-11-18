# Kyverno e2e for cosign-v2 signatures, relocated with cosign save and load.

FLOW := cosign-v2
COSIGN_DIR := ../cosign-v2
POLICY := kyverno-policy-cosign.yaml
POLICY_NAME := check-image-cosign
TRUST := $(COSIGN_DIR)/examples/ca.crt
IMAGE_UNSIGNED := alpine:3.20.2
# cosign-v2 load appends -loaded to the tag it loads into
IMAGE_SIGNED := alpine:3.20.3-loaded

include common.mk

sign:
	$(MAKE) -C $(COSIGN_DIR) clean test pack

relocate:
	$(MAKE) -C $(COSIGN_DIR) load TEST_IMAGE_LOCAL=$(TEST_REGISTRY)/alpine:3.20.3
