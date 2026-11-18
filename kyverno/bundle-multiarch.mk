# Kyverno e2e for multi-arch images from cosign-v4-pre v4-multiarch. Kyverno
# verifies the digest the pod names: for a tag, the index. A bundle on the
# index admits pods by tag and not by platform digest; bundles on the platform
# manifests admit pods by platform digest and not by tag.

FLOW := bundle-multiarch
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5004
POLICY := kyverno-policy-bundle.yaml
POLICY_NAME := check-image-bundle
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/index-only:3.20.3
# linux/amd64 manifest of the index, the platform of the kind node
AMD64 = $(shell oras manifest fetch --plain-http $(TEST_REGISTRY)/$(IMAGE_SIGNED) | \
	jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest')

include common.mk

all: platform-checks

sign:
	$(MAKE) -C $(COSIGN_DIR) clean v4-multiarch

relocate:
	for r in index-only platform-only; do \
		$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/multi/$$r:3.20.3 \
			RELOCATE_REPO=$(TEST_REGISTRY)/bundle/$$r || exit 1; \
	done

platform-checks:
	$(call denied,pod-platform-only,bundle/platform-only:3.20.3,no signatures found)
	$(call denied,pod-index-only-amd64,bundle/index-only@$(AMD64),no signatures found)
	$(call admitted,pod-platform-only-amd64,bundle/platform-only@$(AMD64))
	@echo "[OK] $(FLOW): index bundle admits by tag only, platform bundles by platform digest only"
