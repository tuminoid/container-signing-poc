# Shared by the flow files. Each flow signs in its own registry, relocates the
# signed image with its signatures into a Kind registry, applies its policy,
# then checks admission. The flow file sets FLOW, POLICY, POLICY_NAME, TRUST,
# IMAGE_UNSIGNED and IMAGE_SIGNED, and defines sign and relocate. Further
# checks are prerequisites the flow file adds to all.

# kind-registry (registry:3) by default, kind-zot on 127.0.0.1:5009
TEST_REGISTRY ?= 127.0.0.1:5001
REGISTRY_CONTAINER ?= kind-registry
# Kind network IP of the registry, see scripts/kind-cluster.sh
CLUSTER_REGISTRY = $(shell docker inspect -f \
	'{{(index .NetworkSettings.Networks "kind").IPAddress}}' $(REGISTRY_CONTAINER)):5000
POLICY_DIR := policy
# mutateDigest and verifyDigest in policies that have the __DIGEST__ setting
DIGEST ?= true
# Pinned, as kind create switches the shared current context
KUBECTL := kubectl --context kind-kyverno
# Upstream image pushed unsigned, when IMAGE_UNSIGNED is not an upstream name
UNSIGNED_SOURCE ?= $(IMAGE_UNSIGNED)

# $(call denied,pod,image[,cause]): admission denies a pod running the image,
# naming the cause in the verification details when given
denied = $(KUBECTL) run $(1) --image $(CLUSTER_REGISTRY)/$(2) -- sleep 3600 2>&1 | \
	grep 'denied the request.*$(3)'
# $(call admitted,pod,image): admission admits the pod and it runs
admitted = $(KUBECTL) run $(1) -l flow=$(FLOW) --image $(CLUSTER_REGISTRY)/$(2) -- sleep 3600 && \
	$(KUBECTL) wait --for=condition=Ready pod/$(1) --timeout=120s

SHELL := /bin/bash

.PHONY: all unsigned sign relocate policy test delete

all: unsigned sign relocate policy test

unsigned:
	docker pull $(UNSIGNED_SOURCE)
	docker tag $(UNSIGNED_SOURCE) $(TEST_REGISTRY)/$(IMAGE_UNSIGNED)
	docker push $(TEST_REGISTRY)/$(IMAGE_UNSIGNED)

# Replace the __TRUST__ line in the policy with the TRUST file, indented alike.
policy:
	awk -v f="$(TRUST)" -v d="$(DIGEST)" '/^ *__TRUST__$$/ { \
		ind = substr($$0, 1, index($$0, "_") - 1); \
		while ((getline l < f) > 0) print ind l; close(f); next } \
		{ gsub(/__DIGEST__/, d); print }' \
		$(POLICY_DIR)/$(POLICY) | $(KUBECTL) apply -f -
	$(KUBECTL) wait --for=jsonpath='{.status.conditionStatus.ready}'=true \
		imagevalidatingpolicy/$(POLICY_NAME) --timeout=120s

# Unsigned must be denied by the policy, signed must be admitted and run.
test: delete
	$(call denied,pod-fail-$(FLOW),$(IMAGE_UNSIGNED))
	$(KUBECTL) create deployment deployment-fail-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_UNSIGNED) \
		-- sleep 3600 2>&1 | grep 'denied the request'
	$(call admitted,pod-success-$(FLOW),$(IMAGE_SIGNED))
	$(KUBECTL) create deployment deployment-success-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED) -- sleep 3600
	$(KUBECTL) rollout status deployment/deployment-success-$(FLOW) --timeout=120s
	@echo "[OK] $(FLOW): unsigned rejected, signed admitted and running"

delete:
	$(KUBECTL) delete pod -l flow=$(FLOW) --ignore-not-found
	$(KUBECTL) delete deployment deployment-success-$(FLOW) --ignore-not-found
