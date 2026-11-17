# Shared by cosign-v2.mk, cosign-v3.mk and notation.mk. Each flow signs in its
# own registry, relocates the signed image with its signatures into the Kind
# registry, applies its policy, then checks admission. The flow file sets
# FLOW, POLICY, POLICY_NAME, CA_CERT, IMAGE_UNSIGNED and IMAGE_SIGNED, and
# defines sign and relocate.

TEST_REGISTRY := 127.0.0.1:5001
# The name the Kind nodes and Kyverno both resolve, see scripts/kind-cluster.sh
CLUSTER_REGISTRY := kind-registry:5000
POLICY_DIR := policy

SHELL := /bin/bash

.PHONY: all unsigned sign relocate policy test delete

all: unsigned sign relocate policy test

unsigned:
	docker pull $(IMAGE_UNSIGNED)
	docker tag $(IMAGE_UNSIGNED) $(TEST_REGISTRY)/$(IMAGE_UNSIGNED)
	docker push $(TEST_REGISTRY)/$(IMAGE_UNSIGNED)

# Replace the PEM block in the policy with CA_CERT at the same indentation.
policy:
	awk -v ca="$(CA_CERT)" ' \
		/-----BEGIN CERTIFICATE-----/ { \
			ind = substr($$0, 1, index($$0, "-") - 1); \
			while ((getline l < ca) > 0) print ind l; skip = 1 } \
		!skip { print } \
		/-----END CERTIFICATE-----/ { skip = 0 }' \
		$(POLICY_DIR)/$(POLICY) | kubectl apply -f -
	kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true \
		imagevalidatingpolicy/$(POLICY_NAME) --timeout=120s

# Unsigned must be rejected at admission, signed must be admitted and run.
test: delete
	! kubectl run pod-fail-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_UNSIGNED) -- sleep 3600
	! kubectl create deployment deployment-fail-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_UNSIGNED) -- sleep 3600
	kubectl run pod-success-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED) -- sleep 3600
	kubectl create deployment deployment-success-$(FLOW) --image $(CLUSTER_REGISTRY)/$(IMAGE_SIGNED) -- sleep 3600
	kubectl wait --for=condition=Ready pod/pod-success-$(FLOW) --timeout=120s
	kubectl rollout status deployment/deployment-success-$(FLOW) --timeout=120s
	@echo "[OK] $(FLOW): unsigned rejected, signed admitted and running"

delete:
	kubectl delete pod pod-success-$(FLOW) --ignore-not-found
	kubectl delete deployment deployment-success-$(FLOW) --ignore-not-found
