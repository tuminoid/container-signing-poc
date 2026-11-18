# Kind cluster, registry and Kyverno for the admission flows (*.mk)

KYVERNO_CHART_VERSION := 3.10.0
# zot, the referrers API registry, pinned once in ../cosign-v4-pre/Makefile
ZOT_IMAGE := $(shell sed -n 's/^ZOT_IMAGE := //p' ../cosign-v4-pre/Makefile)

SHELL := /bin/bash

.PHONY: all setup check-tools cluster install-kyverno clean api-versions

all: check-tools
	@echo "targets: setup clean"
	@echo "after 'make setup', run one of:"
	@echo "  make -f cosign-v2.mk"
	@echo "  make -f cosign-v3.mk"
	@echo "  make -f notation.mk"
	@echo "  make -f cosign-v4-pre.mk"

setup: check-tools cluster install-kyverno

check-tools:
	@type -a helm &>/dev/null || { echo "error: Install helm: https://helm.sh/docs/intro/install/"; exit 1; }
	@type -a docker &>/dev/null || { echo "error: Install docker: https://docs.docker.com/engine/install/"; exit 1; }
	@type -a kind &>/dev/null || { echo "error: Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/"; exit 1; }
	@type -a kubectl &>/dev/null || { echo "error: Install kubectl: https://kubernetes.io/docs/tasks/tools/"; exit 1; }

cluster:
	ZOT_IMAGE=$(ZOT_IMAGE) ./scripts/kind-cluster.sh

install-kyverno:
	helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
	helm upgrade --install kyverno kyverno/kyverno --version $(KYVERNO_CHART_VERSION) \
		--kube-context kind-kyverno -n kyverno --create-namespace --wait \
		--set admissionController.container.extraArgs.allowInsecureRegistry=true

clean:
	-docker rm -f kind-registry kind-zot
	-kind delete cluster --name kyverno

# Kyverno 1.20.0 refuses to create the former ClusterPolicy. It serves
# ImageValidatingPolicy v1 and v1beta1 with one schema and no conversion, and
# stores v1beta1.
IVP_VERSIONS := .spec.conversion.strategy == "None" and \
	[.spec.versions[] | select(.storage) | .name] == ["v1beta1"] and \
	([.spec.versions[] | select(.served and (.name == "v1" or .name == "v1beta1")) | .schema] | \
		length == 2 and .[0] == .[1])

api-versions:
	@kubectl --context kind-kyverno apply --dry-run=server -f policy/legacy-clusterpolicy.yaml 2>&1 | \
		grep -q 'no longer accepts create or update requests' || \
		{ echo "[FAIL] the legacy ClusterPolicy was not refused"; exit 1; }
	@kubectl --context kind-kyverno get crd imagevalidatingpolicies.policies.kyverno.io -o json | \
		jq -e '$(IVP_VERSIONS)' >/dev/null || \
		{ echo "[FAIL] ImageValidatingPolicy versions changed"; exit 1; }
	@echo "[OK] ClusterPolicy refused; ImageValidatingPolicy v1 and v1beta1 served alike, v1beta1 stored"
