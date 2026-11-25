# Kyverno e2e for repository binding, cosign-v4-pre v4-repo-binding: one
# policy per repository requires its signed repository annotation. The image
# of binding/app arrives as bundle/app with its bundle, and as bundle/other
# with the same bundle, plus the one with the binding/other certificate
# swapped in. bundle/app is admitted, and its unsigned image denied by the app
# policy; bundle/other is denied by the other policy, its bundles signed for
# repository app.

FLOW := bundle-binding
SUITE := cosign-v4-pre
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5004
POLICIES := kyverno-policy-bundle-repository.yaml
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/app:3.20.2
IMAGE_SIGNED := bundle/app:3.20.3

include common.mk

all: copy-denied

sign:
	$(MAKE) -C $(COSIGN_DIR) clean v4-repo-binding

relocate:
	for r in app other; do \
		$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/binding/$$r:3.20.3 \
			RELOCATE_REPO=$(TEST_REGISTRY)/bundle/$$r || exit 1; \
	done
	oras tag --plain-http $(TEST_REGISTRY)/bundle/other:3.20.3 latest

copy-denied:
	$(call denied,pod-copy,bundle/other:3.20.3,missing or incorrect annotation)
	d=$$(oras resolve --plain-http $(TEST_REGISTRY)/bundle/other:3.20.3) && \
		$(call denied,pod-copy-digest,bundle/other@$$d,missing or incorrect annotation)
	$(call denied,pod-copy-bare,bundle/other,missing or incorrect annotation)
	@echo "[OK] $(FLOW): admitted in its repository, denied as a copy in another, by tag, by digest and bare"
