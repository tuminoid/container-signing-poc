# setup kyverno test for e2e

SCRIPTS_DIR := scripts
POLICY_DIR := policy

TEST_REGISTRY := 127.0.0.1:5001
TEST_REGISTRY_NAME := kind-registry
TEST_REGISTRY_IMAGE := registry:2

KYVERNO_CHART_VERSION := 3.10.0

SHELL := /bin/bash

.PHONY: all setup check-tools setup-registry create-cluster install-kyverno clean

all: check-tools
	@echo "targets: setup clean"
	@echo "after 'make setup', run:"
	@echo "  - 'make -f cosign-v2.mk' (cosign v2)"
	@echo "  - 'make -f cosign-v3.mk' (cosign v3)"
	@echo "  - 'make -f notation.mk' (notation)"

# The registry joins the kind network, which exists once the cluster does.
setup: check-tools create-cluster setup-registry install-kyverno
	@echo "kyverno setup done!"

check-tools:
	@type -a helm &>/dev/null || { echo "error: Install helm: https://helm.sh/docs/intro/install/"; exit 1; }
	@type -a docker &>/dev/null || { echo "error: Install docker: https://docs.docker.com/engine/install/"; exit 1; }
	@type -a kind &>/dev/null || { echo "error: Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/"; exit 1; }
	@type -a kubectl &>/dev/null || { echo "error: Install kubectl: https://kubernetes.io/docs/tasks/tools/"; exit 1; }

setup-registry:
	docker inspect $(TEST_REGISTRY_NAME) >/dev/null 2>&1 || \
	docker run -d -p $(TEST_REGISTRY):5000 --network kind --name $(TEST_REGISTRY_NAME) $(TEST_REGISTRY_IMAGE)

create-cluster:
	kind get clusters | grep -qx kyverno || ./scripts/kind-cluster.sh

install-kyverno:
	helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
	helm upgrade --install kyverno kyverno/kyverno --version $(KYVERNO_CHART_VERSION) \
		-n kyverno --create-namespace --wait \
		--set admissionController.container.extraArgs.allowInsecureRegistry=true

clean:
	-docker rm -f $(TEST_REGISTRY_NAME)
	-kind delete cluster --name kyverno
