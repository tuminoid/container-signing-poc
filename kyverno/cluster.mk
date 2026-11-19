# Cluster per signing directory, included by Makefile and common.mk. SUITE
# names the directory a flow verifies; it gets its own Kind cluster,
# kyverno-<suite>, context kind-kyverno-<suite>, with its own Kyverno version
# and registries on the kind network, so no flow touches another suite's
# cluster. The bundle flows (cosign-v4-pre.mk, bundle-*.mk) share one.

SUITES := cosign-v2 cosign-v3 cosign-v4-pre notation
# 1.19 is the last release that runs ClusterPolicy, 1.20 runs only
# ImageValidatingPolicy and the other policies.kyverno.io types
KYVERNO_cosign-v2 := 1.19
KYVERNO_cosign-v3 := 1.19
KYVERNO_cosign-v4-pre := 1.20
KYVERNO_notation := 1.20
KYVERNO_CHART_1.19 := 3.9.2
KYVERNO_CHART_1.20 := 3.10.0
# Host port of each cluster's registry:3, kyverno-<suite>-registry, and of the
# bundle cluster's zot, kyverno-cosign-v4-pre-zot
REGISTRY_PORT_cosign-v2 := 5013
REGISTRY_PORT_cosign-v3 := 5014
REGISTRY_PORT_cosign-v4-pre := 5001
REGISTRY_PORT_notation := 5015
ZOT_PORT_cosign-v4-pre := 5009

KYVERNO = $(or $(KYVERNO_$(SUITE)),$(error SUITE must be one of $(SUITES)))
KYVERNO_CHART = $(KYVERNO_CHART_$(KYVERNO))
cluster-of = kyverno-$(1)
CLUSTER = $(call cluster-of,$(SUITE))
KUBECTL = kubectl --context kind-$(CLUSTER)
REGISTRY_PORT = $(REGISTRY_PORT_$(SUITE))
ZOT_PORT = $(ZOT_PORT_$(SUITE))
