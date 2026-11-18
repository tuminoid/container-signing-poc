# use oras to move busybox image with signatures to another registry

NOTATION_DIR := ../notation

# registry1 is same as in ../notation, containing container with signature
NOTATION_REGISTRY := 127.0.0.1:5002
# registry2 is a clean registry the image and signature are imported into;
# ../kyverno/notation.mk overrides it with the Kind registry
TEST_REGISTRY := 127.0.0.1:5005
TEST_REGISTRY_NAME := oras-registry
TEST_REGISTRY_IMAGE := registry:2

TEST_TAG := 1.36.1-glibc
TEST_IMAGE := busybox:$(TEST_TAG)
# Resolved from the source registry, see ../notation/Makefile.
TEST_DIGEST = $(shell curl -sfI \
	-H 'Accept: application/vnd.oci.image.manifest.v1+json' \
	-H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
	http://$(NOTATION_REGISTRY)/v2/busybox/manifests/$(TEST_TAG) | \
	awk 'tolower($$1) == "docker-content-digest:" {print $$2}' | tr -d '\r')
TEST_IMAGE1_LOCAL := $(NOTATION_REGISTRY)/$(TEST_IMAGE)
TEST_IMAGE1_SIGN = $(NOTATION_REGISTRY)/busybox@$(TEST_DIGEST)
TEST_IMAGE2_LOCAL := $(TEST_REGISTRY)/$(TEST_IMAGE)
TEST_IMAGE2_SIGN = $(TEST_REGISTRY)/busybox@$(TEST_DIGEST)
TEST_IMAGE_TARBALL := busybox.tar

SHELL := /bin/bash

.PHONY: all test e2e verify-image sign-image registry export-image import-image clean check-tools

all: check-tools
	@echo "targets: test clean"

check-tools:
	@type -a oras &>/dev/null || { echo "error: Install oras: https://oras.land/docs/installation"; exit 1; }
	@type -a notation &>/dev/null || { echo "error: Install notation: https://notaryproject.dev/docs/user-guides/installation/cli/"; exit 1; }

registry:
	docker rm -f $(TEST_REGISTRY_NAME) >/dev/null 2>&1 || true
	docker run -d -p $(TEST_REGISTRY):5000 --name $(TEST_REGISTRY_NAME) $(TEST_REGISTRY_IMAGE)

sign-image:
	# we run full notation test to get signatures
	make -C $(NOTATION_DIR) test

export-image:
	oras cp --recursive --from-plain-http $(TEST_IMAGE1_SIGN) --to-oci-layout $(TEST_IMAGE)
	tar cf busybox.tar busybox
	rm -rf busybox

import-image:
	tar xf busybox.tar
	oras cp --recursive --from-oci-layout $(TEST_IMAGE) --to-plain-http $(TEST_IMAGE2_LOCAL)

verify-image:
	notation verify --insecure-registry $(TEST_IMAGE2_SIGN)

test: check-tools sign-image export-image registry import-image verify-image
	@echo Success!

e2e: check-tools export-image registry import-image verify-image

clean: clean-e2e
	make -C $(NOTATION_DIR) clean

clean-e2e:
	rm -rf busybox.tar busybox
	-docker rm -f $(TEST_REGISTRY_NAME)
