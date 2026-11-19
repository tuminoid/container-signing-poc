# Kyverno e2e for cosign-v3 signatures, relocated with cosign save and load,
# on Kyverno 1.19, which runs both policy APIs. The same legacy signature is
# verified the legacy way, a ClusterPolicy verifyImages rule, the new way, an
# ImageValidatingPolicy, and by both at once, as during a migration. MODES
# selects which; each mode applies only its policies, then checks which
# policy denied the unsigned pod and which verified the signed one.

FLOW := cosign-v3
SUITE := cosign-v3
COSIGN_DIR := ../cosign-v3
LEGACY := check-image-cosign-legacy
NEW := check-image-cosign
MODES ?= legacy new both
POLICIES_legacy := kyverno-policy-cosign-legacy.yaml
POLICIES_new := kyverno-policy-cosign.yaml
POLICIES_both := $(POLICIES_legacy) $(POLICIES_new)
POLICIES = $(POLICIES_$(MODE))
# Both enforce in both mode; whichever webhook runs first denies
DENIED_BY_legacy := $(LEGACY):
DENIED_BY_new := Policy $(NEW) failed
DENIED_BY = $(DENIED_BY_$(MODE))
TRUST := $(COSIGN_DIR)/examples/ca.crt
IMAGE_UNSIGNED := alpine:3.20.2
# cosign-v3 load appends -loaded to the tag it loads into
IMAGE_SIGNED := alpine:3.20.3-loaded
CHECKS := modes
POD := pod-success-$(FLOW)

include common.mk

.PHONY: modes check-legacy check-new check-both

sign:
	$(MAKE) -C $(COSIGN_DIR) clean test pack

relocate:
	$(MAKE) -C $(COSIGN_DIR) load TEST_IMAGE_LOCAL=$(TEST_REGISTRY)/alpine:3.20.3

modes:
	for m in $(MODES); do \
		$(MAKE) -f cosign-v3.mk MODE=$$m policy test check-$$m || exit 1; \
	done

# The verifyImages annotation is written by the ClusterPolicy path only, the
# policy report by both
check-legacy:
	@$(call legacy-passed,$(POD),$(LEGACY))
	@echo "[OK] $(FLOW): legacy alone, verified by the ClusterPolicy verifyImages rule"

check-new:
	@$(call reported,$(POD),$(NEW),pass)
	@p=$$($(KUBECTL) get pod $(POD) -o json) && \
		! jq -e '.metadata.annotations | has("kyverno.io/verify-images-scoped")' <<< "$$p" >/dev/null || \
		{ echo "[FAIL] $(POD): the ClusterPolicy path verified it"; exit 1; }
	@echo "[OK] $(FLOW): new alone, verified by the ImageValidatingPolicy"

check-both:
	@$(call legacy-passed,$(POD),$(LEGACY))
	@$(call reported,$(POD),$(NEW),pass)
	@$(call reported,$(POD),$(LEGACY),pass)
	@echo "[OK] $(FLOW): both at once, the signed pod passed the ClusterPolicy and the ImageValidatingPolicy"
