# Kyverno e2e on zot, which serves the OCI referrers API: cosign-v4-pre
# v4-referrers signs and relocates on zot, the image is relocated into kind-zot
# and admitted from there. kind-zot lists the bundle in the referrers API and
# holds no fallback tag, so Kyverno found the bundle through the API.

FLOW := bundle-zot
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5008
TEST_REGISTRY := 127.0.0.1:5009
REGISTRY_CONTAINER := kind-zot
POLICY := kyverno-policy-bundle.yaml
POLICY_NAME := check-image-bundle
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/alpine:3.20.3

include common.mk

all: no-fallback-tag

sign:
	$(MAKE) -C $(COSIGN_DIR) clean v4-referrers

relocate:
	$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/alpine:3.20.3 \
		RELOCATE_REPO=$(TEST_REGISTRY)/bundle/alpine

no-fallback-tag:
	@d=$$(oras resolve --plain-http $(TEST_REGISTRY)/$(IMAGE_SIGNED)) && [ -n "$$d" ] || \
		{ echo "[FAIL] cannot resolve $(IMAGE_SIGNED)"; exit 1; }; \
	n=$$(curl -sf http://$(TEST_REGISTRY)/v2/bundle/alpine/referrers/$$d | \
		jq '[.manifests[] | select(.artifactType == "application/vnd.dev.sigstore.bundle.v0.3+json")] | length'); \
	[ "$$n" = 1 ] || { echo "[FAIL] kind-zot referrers API: $$n bundles"; exit 1; }; \
	s=$$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.oci.image.index.v1+json' \
		http://$(TEST_REGISTRY)/v2/bundle/alpine/manifests/$${d/:/-}); \
	[ "$$s" = 404 ] || { echo "[FAIL] kind-zot has a fallback tag: $$s"; exit 1; }
	@echo "[OK] $(FLOW): admitted through the referrers API"
