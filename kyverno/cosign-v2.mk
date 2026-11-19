# Kyverno e2e for cosign-v2 signatures, relocated with cosign save and load:
# the legacy signature verified the legacy way, a ClusterPolicy verifyImages
# rule on Kyverno 1.19, the last release that runs it. The unsigned pod is
# denied by that policy, and the signed pod carries its verifyImages pass.

FLOW := cosign-v2
SUITE := cosign-v2
COSIGN_DIR := ../cosign-v2
LEGACY := check-image-cosign-legacy
POLICIES := kyverno-policy-cosign-legacy.yaml
DENIED_BY := $(LEGACY)
TRUST := $(COSIGN_DIR)/examples/ca.crt
IMAGE_UNSIGNED := alpine:3.20.2
# cosign-v2 load appends -loaded to the tag it loads into
IMAGE_SIGNED := alpine:3.20.3-loaded

include common.mk

all: legacy-verified

sign:
	$(MAKE) -C $(COSIGN_DIR) clean test pack

relocate:
	$(MAKE) -C $(COSIGN_DIR) load TEST_IMAGE_LOCAL=$(TEST_REGISTRY)/alpine:3.20.3

legacy-verified:
	@$(call legacy-passed,pod-success-$(FLOW),$(LEGACY))
	@echo "[OK] $(FLOW): verified by the ClusterPolicy verifyImages rule on Kyverno $(KYVERNO)"
