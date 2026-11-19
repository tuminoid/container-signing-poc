# Kyverno e2e for Sigstore bundles from cosign-v4-pre in the admissible shape
# (leaf only, signed timestamp), relocated with oras via an OCI layout tarball.
# SIGN_TARGET is the signing flow: v4-tsa, cosign with a P-384 leaf, or v4-rsa,
# cosign-free with an RSA 4096 leaf. DIGEST=false turns mutateDigest and
# verifyDigest off.

FLOW := cosign-v4-pre
SUITE := cosign-v4-pre
COSIGN_DIR := ../cosign-v4-pre
SIGN_TARGET ?= v4-tsa
POLICIES := kyverno-policy-bundle.yaml
TRUST := $(COSIGN_DIR)/examples/trusted-root-tsa.json
UNSIGNED_SOURCE := alpine:3.20.2
IMAGE_UNSIGNED := bundle/alpine:3.20.2
IMAGE_SIGNED := bundle/alpine:3.20.3

include common.mk

all: digest-check

sign:
	$(MAKE) -C $(COSIGN_DIR) clean $(SIGN_TARGET)

relocate:
	$(MAKE) -C $(COSIGN_DIR) relocate RELOCATE_REPO=$(TEST_REGISTRY)/bundle/alpine

# mutateDigest rewrites the admitted tag reference to tag@digest; with both
# settings off the pod keeps the tag reference.
digest-check:
	@img=$$($(KUBECTL) get pod pod-success-$(FLOW) -o jsonpath='{.spec.containers[0].image}'); \
	case "$(DIGEST) $$img" in \
	"true $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED)@sha256:"*|"false $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED)") \
		echo "[OK] DIGEST=$(DIGEST): admitted pod runs $$img" ;; \
	*) echo "[FAIL] DIGEST=$(DIGEST): admitted pod runs $$img"; exit 1 ;; \
	esac
