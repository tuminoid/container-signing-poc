# Kind clusters, registries and Kyverno for the admission flows (*.mk). Each
# flow names its suite, SUITE, and runs setup itself, which creates that
# suite's cluster with its Kyverno version if missing; see cluster.mk.

include cluster.mk

# zot, the referrers API registry, pinned once in ../cosign-v4-pre/Makefile
ZOT_IMAGE := $(shell sed -n 's/^ZOT_IMAGE := //p' ../cosign-v4-pre/Makefile)

SHELL := /bin/bash

.PHONY: all setup check-tools cluster install-kyverno version-check clean api-versions

all: check-tools
	@echo "targets: setup clean api-versions"
	@echo "flows, each running setup for its suite's cluster:"
	@echo "  make -f cosign-v2.mk"
	@echo "  make -f cosign-v3.mk MODES='legacy new both'"
	@echo "  make -f notation.mk"
	@echo "  make -f cosign-v4-pre.mk"

setup: check-tools cluster install-kyverno

check-tools:
	@type -a helm &>/dev/null || { echo "error: Install helm: https://helm.sh/docs/intro/install/"; exit 1; }
	@type -a docker &>/dev/null || { echo "error: Install docker: https://docs.docker.com/engine/install/"; exit 1; }
	@type -a kind &>/dev/null || { echo "error: Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/"; exit 1; }
	@type -a kubectl &>/dev/null || { echo "error: Install kubectl: https://kubernetes.io/docs/tasks/tools/"; exit 1; }

cluster:
	CLUSTER=$(CLUSTER) REGISTRY_PORT=$(REGISTRY_PORT) ZOT_PORT=$(ZOT_PORT) \
		ZOT_IMAGE=$(ZOT_IMAGE) ./scripts/kind-cluster.sh

# An ImageValidatingPolicy matching pods/ephemeralcontainers, which it needs to
# see the ephemeral containers of kubectl debug, is ready only once the
# reports controller may read that subresource.
install-kyverno:
	helm upgrade --install kyverno kyverno --repo https://kyverno.github.io/kyverno/ \
		--version $(KYVERNO_CHART) \
		--kube-context kind-$(CLUSTER) -n kyverno --create-namespace --wait \
		--set admissionController.container.extraArgs.allowInsecureRegistry=true \
		--set-json 'reportsController.rbac.clusterRole.extraResources=[{"apiGroups": [""], "resources": ["pods/ephemeralcontainers"]}]'

# The suite's cluster must run its Kyverno version
version-check:
	@v=$$($(KUBECTL) -n kyverno get deploy kyverno-admission-controller \
		-o jsonpath='{.spec.template.spec.containers[0].image}'); \
	case "$$v" in *:v$(KYVERNO).*) ;; \
	*) echo "[FAIL] $(CLUSTER) runs Kyverno $$v, not $(KYVERNO): make setup SUITE=$(SUITE)"; exit 1 ;; esac

clean:
	-docker rm -f $(foreach s,$(SUITES),$(call cluster-of,$(s))-registry $(call cluster-of,$(s))-zot)
	-$(foreach s,$(SUITES),kind delete cluster --name $(call cluster-of,$(s));)

# Kyverno 1.20.0, here the bundle cluster's, refuses to create the former
# ClusterPolicy. It serves ImageValidatingPolicy v1 and v1beta1 with one schema
# and no conversion, and stores v1beta1.
IVP_VERSIONS := .spec.conversion.strategy == "None" and \
	[.spec.versions[] | select(.storage) | .name] == ["v1beta1"] and \
	([.spec.versions[] | select(.served and (.name == "v1" or .name == "v1beta1")) | .schema] | \
		length == 2 and .[0] == .[1])

api-versions: SUITE := cosign-v4-pre
api-versions: version-check
	@$(KUBECTL) apply --dry-run=server -f policy/kyverno-policy-cosign-legacy.yaml 2>&1 | \
		grep -q 'no longer accepts create or update requests' || \
		{ echo "[FAIL] the legacy ClusterPolicy was not refused"; exit 1; }
	@$(KUBECTL) get crd imagevalidatingpolicies.policies.kyverno.io -o json | \
		jq -e '$(IVP_VERSIONS)' >/dev/null || \
		{ echo "[FAIL] ImageValidatingPolicy versions changed"; exit 1; }
	@echo "[OK] ClusterPolicy refused; ImageValidatingPolicy v1 and v1beta1 served alike, v1beta1 stored"
