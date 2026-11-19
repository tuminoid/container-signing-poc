# Kyverno e2e for Notation signatures, relocated with oras via an OCI layout
# tarball.

FLOW := notation
SUITE := notation
NOTATION_DIR := ../notation
POLICIES := kyverno-policy-notation.yaml
TRUST := $(NOTATION_DIR)/examples/ca.crt
IMAGE_UNSIGNED := busybox:1.36.0-glibc
IMAGE_SIGNED := busybox:1.36.1-glibc

include common.mk

sign:
	$(MAKE) -C $(NOTATION_DIR) clean test

relocate:
	$(MAKE) -C ../oras export-image import-image TEST_REGISTRY=$(TEST_REGISTRY)
