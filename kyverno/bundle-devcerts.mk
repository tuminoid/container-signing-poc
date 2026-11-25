# Kyverno e2e for the EPPKI C1 dev kit, cosign-v4-pre v4-devcerts: DEVCERTS
# names the extracted kit. The policy trusts the kit's root and
# SubCA_C1_dev_2 and pins the kit's URI SAN with an empty issuer. The valid
# certificate is admitted, and so is the one the kit's CRL revokes, as no CRL
# is read; the expired one, and the one of the revoked SubCA_C1_dev_5, which
# the trusted root lacks, are denied, and so is that one with SubCA_C1_dev_5
# in its bundle, as Kyverno takes no chain from a bundle. The valid one is
# denied under a policy pinned to another SAN.

FLOW := bundle-devcerts
SUITE := cosign-v4-pre
COSIGN_DIR := ../cosign-v4-pre
SOURCE := 127.0.0.1:5004
POLICIES := kyverno-policy-bundle.yaml
TRUST := $(COSIGN_DIR)/examples/devcerts/trusted-root.json
SUBJECT := https://www.ericsson.com/en/about-us/security/pki
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/dev-ok:3.20.3

include common.mk

all: dev-cases

sign:
	$(MAKE) -C $(COSIGN_DIR) devkit-check clean v4-devcerts

relocate:
	for r in ok revoked expired revoked-ca revoked-ca-chain; do \
		$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_SRC=$(SOURCE)/devcerts/$$r:3.20.3 \
			RELOCATE_REPO=$(TEST_REGISTRY)/bundle/dev-$$r || exit 1; \
	done

dev-cases:
	$(call admitted,pod-dev-revoked,bundle/dev-revoked:3.20.3)
	$(call denied,pod-dev-expired,bundle/dev-expired:3.20.3,failed to verify leaf certificate)
	$(call denied,pod-dev-revoked-ca,bundle/dev-revoked-ca:3.20.3,failed to verify leaf certificate)
	$(call denied,pod-dev-revoked-ca-chain,bundle/dev-revoked-ca-chain:3.20.3,no signatures found)
	$(MAKE) -f bundle-devcerts.mk policy SUBJECT=https://signing.example.com
	$(call denied,pod-dev-other-san,bundle/dev-ok:3.20.3,failed to verify certificate identity)
	$(MAKE) -f bundle-devcerts.mk policy
	$(call admitted,pod-dev-ok-again,bundle/dev-ok:3.20.3)
	@echo "[OK] $(FLOW): valid and CRL-revoked admitted; expired, revoked CA, with or without its intermediate, and another SAN denied"
