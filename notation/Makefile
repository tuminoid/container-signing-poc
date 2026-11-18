# build and install notation-external-signer

SRC_DIR := cmd/notation-external-signer
SRC_BIN := notation-external-signer
TGT_DIR := $(HOME)/.config/notation/plugins/external-signer
TGT_BIN := notation-external-signer
EXAMPLES_DIR := examples

TEST_REGISTRY := 127.0.0.1:5002
TEST_REGISTRY_NAME := notation-registry
TEST_REGISTRY_IMAGE := registry:2
TEST_IMAGE := busybox
TEST_IMAGE_TAG := 1.36.1-glibc
TEST_DIGEST := sha256:9bc27a72a82d22e54b4cc8bd7b99d3907a442869f77f075e0119104f2404953d
TEST_IMAGE_LOCAL := $(TEST_REGISTRY)/$(TEST_IMAGE):$(TEST_IMAGE_TAG)
# The pushed manifest digest depends on the docker image store, so resolve it
# from the registry after push.
TEST_DIGEST_LOCAL = $(shell curl -sfI \
	-H 'Accept: application/vnd.oci.image.manifest.v1+json' \
	-H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
	http://$(TEST_REGISTRY)/v2/$(TEST_IMAGE)/manifests/$(TEST_IMAGE_TAG) | \
	awk 'tolower($$1) == "docker-content-digest:" {print $$2}' | tr -d '\r')
TEST_IMAGE_SIGN = $(TEST_REGISTRY)/$(TEST_IMAGE)@$(TEST_DIGEST_LOCAL)

SHELL := /bin/bash

.PHONY: all build install clean registry test sign verify e2e clean-e2e check-tools

all: check-tools
	@echo "targets: build install test verify clean"

check-tools:
	@type -a docker &>/dev/null || { echo "error: Install docker: https://docs.docker.com/engine/install/"; exit 1; }
	@type -a notation &>/dev/null || { echo "error: Install notation: https://notaryproject.dev/docs/user-guides/installation/cli/"; exit 1; }

build:
	rm -f "$(SRC_DIR)/$(SRC_BIN)"
	cd "$(SRC_DIR)" && go build .

install: build
	mkdir -p "$(TGT_DIR)"
	mv "$(SRC_DIR)/$(SRC_BIN)" "$(TGT_DIR)/$(TGT_BIN)"

clean:
	rm -f "$(SRC_DIR)/$(SRC_BIN)"
	rm -rf "$(TGT_DIR)"
	rm -f $(EXAMPLES_DIR)/*.{cer,crt,csr,key,pem,srl}
	docker rm -f $(TEST_REGISTRY_NAME) 2>/dev/null || true
	-notation cert delete -s external -t ca --all -y

clean-e2e: clean

registry:
	docker rm -f $(TEST_REGISTRY_NAME) >/dev/null 2>&1 || true
	docker run -d -p $(TEST_REGISTRY):5000 --name $(TEST_REGISTRY_NAME) $(TEST_REGISTRY_IMAGE)
	docker pull $(TEST_IMAGE):$(TEST_IMAGE_TAG)@$(TEST_DIGEST)
	docker tag $(TEST_IMAGE)@$(TEST_DIGEST) $(TEST_IMAGE_LOCAL)
	docker push $(TEST_IMAGE_LOCAL)

certificates:
	openssl genrsa -out $(EXAMPLES_DIR)/ca.key 4096
	openssl req -new -x509 -days 365 -key $(EXAMPLES_DIR)/ca.key \
		-subj "/O=Notation/CN=Notation Root CA" \
		-out $(EXAMPLES_DIR)/ca.crt -addext "keyUsage=critical,keyCertSign"

	openssl genrsa -out $(EXAMPLES_DIR)/leaf.key 4096
	openssl req -newkey rsa:4096 -nodes -keyout $(EXAMPLES_DIR)/leaf.key \
		-subj "/CN=Notation.leaf" -out $(EXAMPLES_DIR)/leaf.csr

	openssl x509 -req \
		-extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature") \
		-days 365 -in $(EXAMPLES_DIR)/leaf.csr -CA $(EXAMPLES_DIR)/ca.crt -CAkey $(EXAMPLES_DIR)/ca.key \
		-CAcreateserial -out $(EXAMPLES_DIR)/leaf.crt

	cat $(EXAMPLES_DIR)/leaf.crt $(EXAMPLES_DIR)/ca.crt > $(EXAMPLES_DIR)/certificate_chain.pem

test: check-tools install registry certificates sign verify
e2e: test

sign:
	EXTERNAL_CERT_CHAIN=$(EXAMPLES_DIR)/certificate_chain.pem \
	EXTERNAL_PRIVATE_KEY=$(EXAMPLES_DIR)/leaf.key \
	EXTERNAL_SIGNER=$(EXAMPLES_DIR)/rsassa-pss-sha512.sh \
	notation sign --debug --insecure-registry --id "anything" --plugin "external-signer" $(TEST_IMAGE_SIGN)

inspect:
	notation inspect --insecure-registry $(TEST_IMAGE_SIGN)

verify: inspect
	-notation cert delete -s external -t ca --all -y
	notation cert add -t ca -s external "$(EXAMPLES_DIR)/ca.crt"
	notation policy import --force $(EXAMPLES_DIR)/trustpolicy.json
	notation verify --insecure-registry -v $(TEST_IMAGE_SIGN)
