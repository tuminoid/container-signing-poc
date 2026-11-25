# Kyverno tripwires for the bundle shapes of cosign-v4-pre v4-shapes, all of
# which cosign verifies: only the leaf alone with a signed timestamp is
# admitted. Leaf plus intermediate, and the leaf alone without timestamp, are
# denied; a Kyverno release that admits either fails this flow. The legacy
# signature of v4-legacy-fallback, by the same PKI, without timestamp and
# without bundle, is admitted: with no bundle Kyverno verifies legacy
# signatures, and requires no timestamp there.

FLOW := bundle-shapes
SUITE := cosign-v4-pre
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5004
POLICIES := kyverno-policy-bundle.yaml
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/leaf-tsa:3.20.3

include common.mk

all: shapes-denied

sign:
	$(MAKE) -C $(COSIGN_DIR) clean v4-shapes v4-legacy-fallback

relocate:
	for s in leaf-tsa chain-tsa leaf; do \
		$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/shapes/$$s:3.20.3 \
			RELOCATE_REPO=$(TEST_REGISTRY)/bundle/$$s || exit 1; \
	done
	d=$$(oras resolve --plain-http $(SOURCE)/legacy/alpine:3.20.3) && \
	oras cp --from-plain-http --to-plain-http $(SOURCE)/legacy/alpine:3.20.3 \
		$(TEST_REGISTRY)/bundle/legacy:3.20.3 && \
	oras cp --from-plain-http --to-plain-http $(SOURCE)/legacy/alpine:$${d/:/-}.sig \
		$(TEST_REGISTRY)/bundle/legacy:$${d/:/-}.sig

shapes-denied:
	$(call denied,pod-chain-tsa,bundle/chain-tsa:3.20.3,no signatures found)
	$(call denied,pod-leaf,bundle/leaf:3.20.3,threshold not met for verified signed timestamps)
	$(call admitted,pod-legacy,bundle/legacy:3.20.3)
	@echo "[OK] $(FLOW): leaf plus intermediate denied, leaf without timestamp denied, legacy signature admitted"
