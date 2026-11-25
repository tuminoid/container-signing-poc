# Shared by the flow files. Each flow sets up its suite's cluster, signs in
# its own registry, relocates the signed image with its signatures into the
# cluster's registry, applies its policies alone, then checks admission. The
# flow file sets FLOW, SUITE, POLICIES, TRUST, IMAGE_UNSIGNED and
# IMAGE_SIGNED, and defines sign and relocate. Further checks are
# prerequisites the flow file adds to all.

# SUITE selects the cluster, its Kyverno version and KUBECTL
include cluster.mk
# The cluster's registry:3 by default; bundle-zot.mk uses its zot
TEST_REGISTRY ?= 127.0.0.1:$(REGISTRY_PORT)
REGISTRY_CONTAINER ?= $(CLUSTER)-registry
# Kind network IP of the registry, see scripts/kind-cluster.sh
CLUSTER_REGISTRY = $(shell docker inspect -f \
	'{{(index .NetworkSettings.Networks "kind").IPAddress}}' $(REGISTRY_CONTAINER)):5000
POLICY_DIR := policy
# mutateDigest and verifyDigest in policies that have the __DIGEST__ setting
DIGEST ?= true
# Text the denial of the unsigned pod must contain, naming the policy
DENIED_BY ?=
# What admission does to an unsigned kubectl debug ephemeral container,
# denied or admitted
EPHEMERAL ?= denied
# Admission checks after relocation
CHECKS ?= policy test
# Upstream image pushed unsigned, when IMAGE_UNSIGNED is not an upstream name
UNSIGNED_SOURCE ?= $(IMAGE_UNSIGNED)

# $(call refused,what,command[,cause]): admission denies the request the
# command makes, naming the cause when given
refused = out=$$($(2) 2>&1); \
	grep -q 'denied the request' <<< "$$out" && grep -qF '$(3)' <<< "$$out" || \
	{ echo "[FAIL] $(1): not denied$(if $(3), by $(3)): $$out"; exit 1; }
# $(call denied,pod,image[,cause]): admission denies a pod running the image,
# naming the cause when given
denied = $(call refused,$(1),$(KUBECTL) run $(1) --image $(CLUSTER_REGISTRY)/$(2) -- sleep 3600,$(3))
# An unsigned ephemeral container in a signed pod of its own, so a flow's
# checks of pod-success see no ephemeral container
DEBUG_UNSIGNED = $(KUBECTL) debug pod-debug-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_UNSIGNED) -- sleep 3600
# A signed pod with an unsigned init container
UNSIGNED_INIT = {"apiVersion": "v1", "spec": {"initContainers": [{"name": "init", \
	"image": "$(CLUSTER_REGISTRY)/$(IMAGE_UNSIGNED)", "command": ["true"]}]}}
# $(call admitted,pod,image): admission admits the pod and it runs
admitted = $(KUBECTL) run $(1) -l flow=$(FLOW) --image $(CLUSTER_REGISTRY)/$(2) -- sleep 3600 && \
	$(KUBECTL) wait --for=condition=Ready pod/$(1) --timeout=120s
# $(call legacy-passed,pod,policy): the ClusterPolicy verifyImages rule passed
# the pod's image, as recorded in the annotation only that path writes
legacy-passed = $(KUBECTL) get pod $(1) -o json | \
	jq -e --arg p /$(2) '.metadata.annotations["kyverno.io/verify-images-scoped"] // "{}" | fromjson | \
		.policies[$$p] // {} | [.[][]] | length > 0 and all(. == "pass")' >/dev/null || \
	{ echo "[FAIL] $(1): no verifyImages pass from $(2)"; exit 1; }
# $(call reported,pod,policy,result): the policy report of this pod records
# the policy with that result; the reports controller writes it within a minute
reported = uid=$$($(KUBECTL) get pod $(1) -o jsonpath='{.metadata.uid}'); ok=; \
	for i in $$(seq 1 30); do $(KUBECTL) get policyreports -n default -o json | \
		jq -e --arg u "$$uid" --arg p $(2) '[.items[] | select(.scope.uid == $$u) | .results[] | \
			select(.policy == $$p) | .result] | length > 0 and all(. == "$(3)")' >/dev/null && \
		{ ok=1; break; }; sleep 3; done; \
	[ -n "$$ok" ] || { echo "[FAIL] $(1): policy report has no $(3) from $(2)"; exit 1; }
# No resource webhook of a ClusterPolicy or an ImageValidatingPolicy remains
NO_POLICY_WEBHOOKS := [.items[].webhooks[]?.name | \
	select(test("^(ivpol\\.|mutate\\.kyverno\\.svc-|validate\\.kyverno\\.svc-)"))] | length == 0
# kubectl on kyverno.io types warns that they are deprecated; drop only that
NO_DEPRECATION := 2> >(grep -v 'is deprecated' >&2)

SHELL := /bin/bash

.PHONY: all setup unsigned sign relocate policy-reset policy test delete

all: setup unsigned sign relocate $(CHECKS)

setup:
	$(MAKE) -f Makefile setup SUITE=$(SUITE)

unsigned:
	docker pull $(UNSIGNED_SOURCE)
	docker tag $(UNSIGNED_SOURCE) $(TEST_REGISTRY)/$(IMAGE_UNSIGNED)
	docker push $(TEST_REGISTRY)/$(IMAGE_UNSIGNED)

# Drop every policy, so only this flow's are enforced, and wait until their
# admission webhooks are gone.
policy-reset:
	$(KUBECTL) delete clusterpolicies.kyverno.io,imagevalidatingpolicies.policies.kyverno.io \
		--all --ignore-not-found $(NO_DEPRECATION)
	@for i in $$(seq 1 60); do \
		$(KUBECTL) get mutatingwebhookconfigurations,validatingwebhookconfigurations -o json | \
			jq -e '$(NO_POLICY_WEBHOOKS)' >/dev/null && exit 0; \
		sleep 2; done; echo "[FAIL] policy webhooks remain"; exit 1

# Apply each policy with the __TRUST__ line replaced by the TRUST file,
# indented alike, and __DIGEST__ by DIGEST; wait until each is ready.
policy: policy-reset
	$(MAKE) -f Makefile version-check SUITE=$(SUITE)
	for f in $(POLICIES); do \
		r=$$(awk -v f="$(TRUST)" -v d="$(DIGEST)" '/^ *__TRUST__$$/ { \
			ind = substr($$0, 1, index($$0, "_") - 1); \
			while ((getline l < f) > 0) print ind l; close(f); next } \
			{ gsub(/__DIGEST__/, d); print }' $(POLICY_DIR)/$$f | \
			$(KUBECTL) apply -o name -f - $(NO_DEPRECATION)) || exit 1; \
		case "$$r" in \
		clusterpolicy.*) $(KUBECTL) wait --for=condition=Ready "$$r" --timeout=120s ;; \
		*) $(KUBECTL) wait --for=jsonpath='{.status.conditionStatus.ready}'=true "$$r" --timeout=120s ;; \
		esac || exit 1; \
	done

# Unsigned must be denied by the policy, as a container, an init container or,
# unless EPHEMERAL says otherwise, an ephemeral container; signed must be
# admitted and run.
test: delete
	$(call denied,pod-fail-$(FLOW),$(IMAGE_UNSIGNED),$(DENIED_BY))
	$(call refused,pod-init-fail-$(FLOW),$(KUBECTL) run pod-init-fail-$(FLOW) \
		--image $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED) --overrides '$(UNSIGNED_INIT)' -- sleep 3600,$(DENIED_BY))
	$(KUBECTL) create deployment deployment-fail-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_UNSIGNED) \
		-- sleep 3600 2>&1 | grep 'denied the request'
	$(call admitted,pod-success-$(FLOW),$(IMAGE_SIGNED))
	$(call admitted,pod-debug-$(FLOW),$(IMAGE_SIGNED))
	$(if $(filter denied,$(EPHEMERAL)),$(call refused,ephemeral container in pod-debug-$(FLOW),$(DEBUG_UNSIGNED),$(DENIED_BY)),\
		$(DEBUG_UNSIGNED) >/dev/null && echo "[OK] $(FLOW): unsigned ephemeral container admitted")
	$(KUBECTL) create deployment deployment-success-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED) -- sleep 3600
	$(KUBECTL) rollout status deployment/deployment-success-$(FLOW) --timeout=120s
	@echo "[OK] $(FLOW): unsigned rejected, signed admitted and running"

delete:
	$(KUBECTL) delete pod -l flow=$(FLOW) --ignore-not-found --wait
	$(KUBECTL) delete deployment deployment-success-$(FLOW) --ignore-not-found --wait
