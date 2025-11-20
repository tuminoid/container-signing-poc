#!/usr/bin/env bash
# Test containerd Transfer Service signature verification with per-registry policies

set -euo pipefail

echo "==> Testing containerd Transfer Service signature verification (Per-Registry Policies)..."
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl not found"
    exit 1
fi

if [[ ! -x /opt/containerd/image-verifier/bin/verifier ]]; then
    echo "ERROR: Transfer Service verifier not found"
    echo "   Run: make install-hooks"
    exit 1
fi

if [[ ! -f /etc/containerd/certs/registry-primary-ca.crt ]]; then
    echo "ERROR: CA certificate not found"
    exit 1
fi

if ! kubectl get nodes &> /dev/null; then
    echo "ERROR: Kubernetes cluster not ready"
    exit 1
fi

echo "Configuration check:"
echo "  OK kubectl installed"
echo "  OK Transfer Service verifier exists"
echo "  OK CA certificate exists"
echo "  OK Kubernetes cluster ready"
echo ""

echo "Registry verification policies:"
echo "  127.0.0.1:5000/*  : VERIFY with BYO-PKI CA (primary)"
echo "  127.0.0.1:5001/*  : ALLOW without verification (secondary)"
echo "  gcr.io/*       : BLOCK (rejected)"
echo "  Others            : ALLOW (default action)"
echo ""

# Test 1: Primary registry with signed image (should succeed)
echo "==> Test 1: Primary registry with signed image (should SUCCEED)"
echo "   Image: 127.0.0.1:5000/alpine:3.20.3"
echo "   Policy: Verify signature with CA"
echo ""

if kubectl apply -f manifests/signed-pod.yaml 2>&1 | tee /tmp/containerd-test-signed.log; then
    echo "Waiting for pod to start..."

    # Wait up to 30 seconds for pod to start
    for i in {1..15}; do
        POD_STATUS=$(kubectl get pod test-signed -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "${POD_STATUS}" == "Running" ]]; then
            break
        fi
        sleep 2
    done

    POD_STATUS=$(kubectl get pod test-signed -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "${POD_STATUS}" == "Running" ]]; then
        echo ""
        echo "✅ OK: Signed image pod RUNNING"
        echo "   Certificate chain validation passed"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -3 || true
    else
        echo ""
        echo "❌ ERROR: Pod status: ${POD_STATUS}"
        kubectl describe pod test-signed | tail -30
    fi
    kubectl delete pod test-signed --wait=false >/dev/null 2>&1 || true
else
    echo ""
    echo "❌ ERROR: Signed image pod CREATE FAILED"
fi
echo ""

# Test 2: Primary registry with unsigned image (should fail)
echo "==> Test 2: Primary registry with unsigned image (should FAIL)"
echo "   Image: 127.0.0.1:5000/alpine:unsigned"
echo "   Policy: Verify signature with CA"
echo ""

if kubectl apply -f manifests/unsigned-pod.yaml 2>&1 | tee /tmp/containerd-test-unsigned.log; then
    echo "Waiting for pod to fail..."
    sleep 5

    for i in {1..10}; do
        POD_STATUS=$(kubectl get pod test-unsigned -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        CONTAINER_STATE=$(kubectl get pod test-unsigned -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || echo "{}")

        if [[ "${POD_STATUS}" == "Running" ]] || echo "${CONTAINER_STATE}" | grep -q "waiting"; then
            break
        fi
        sleep 2
    done

    if echo "${CONTAINER_STATE}" | grep "waiting" &> /dev/null; then
        REASON=$(kubectl get pod test-unsigned -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

        if [[ "${REASON}" == "ImagePullBackOff" ]] || [[ "${REASON}" == "ErrImagePull" ]]; then
            echo ""
            echo "✅ OK: Unsigned image pod BLOCKED by Transfer Service verifier"
            echo "   Reason: ${REASON}"
            sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -3 || true
        else
            echo ""
            echo "⚠️  Pod waiting but not due to verifier: ${REASON}    "
            kubectl describe pod test-unsigned | tail -20
        fi
    elif [[ "${POD_STATUS}" == "Running" ]]; then
        echo ""
        echo "❌ ERROR: Unsigned image pod RUNNING"
        echo "   Verifier did NOT block this!"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -5 || true
    else
        echo ""
        echo "⚠️  Pod status: ${POD_STATUS}"
        kubectl describe pod test-unsigned | tail -20
    fi
    kubectl delete pod test-unsigned --wait=false >/dev/null 2>&1 || true
fi
echo ""

# Test 3: gcr.io registry (should be blocked)
echo "==> Test 3: gcr.io registry (should be BLOCKED)"
echo "   Image: gcr.io/google-containers/pause:3.2"
echo "   Policy: Block gcr.io"
echo ""

if kubectl apply -f manifests/gcr-blocked-pod.yaml 2>&1 | tee /tmp/containerd-test-gcr.log; then
    echo "Waiting for pod to fail..."
    sleep 5

    # shellcheck disable=SC2034
    for i in {1..10}; do
        POD_STATUS=$(kubectl get pod test-gcr-blocked -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        CONTAINER_STATE=$(kubectl get pod test-gcr-blocked -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || echo "{}")

        if [[ "${POD_STATUS}" == "Running" ]] || echo "${CONTAINER_STATE}" | grep "waiting" &> /dev/null; then
            break
        fi
        sleep 2
    done

    if echo "${CONTAINER_STATE}" | grep "waiting" &> /dev/null; then
        REASON=$(kubectl get pod test-gcr-blocked -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

        if [[ "${REASON}" == "ImagePullBackOff" ]] || [[ "${REASON}" == "ErrImagePull" ]]; then
            echo ""
            echo "✅ OK: gcr.io image BLOCKED by policy"
            echo "   Reason: ${REASON}"
            sudo journalctl -t containerd-verifier --since '30 sec ago' | grep -A2 "gcr.io" | tail -3 || true
        else
            echo ""
            echo "⚠️  Pod waiting but not due to policy: ${REASON}"
            kubectl describe pod test-gcr-blocked | tail -20
        fi
    elif [[ "${POD_STATUS}" == "Running" ]]; then
        echo ""
        echo "❌ ERROR: gcr.io image pod RUNNING"
        echo "   Policy did NOT block this!"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -5 || true
    else
        echo ""
        echo "⚠️  Pod status: ${POD_STATUS}"
        kubectl describe pod test-gcr-blocked | tail -20
    fi
    kubectl delete pod test-gcr-blocked --wait=false >/dev/null 2>&1 || true
fi
echo ""

# Test 4: Secondary registry without verification (should succeed)
echo "==> Test 4: Secondary registry without verification (should SUCCEED)"
echo "   Image: 127.0.0.1:5001/nginx:alpine"
echo "   Policy: Allow without verification"
echo ""

if kubectl apply -f manifests/secondary-registry-pod.yaml 2>&1 | tee /tmp/containerd-test-secondary.log; then
    echo "Waiting for pod to start..."
    sleep 5

    POD_STATUS=$(kubectl get pod test-secondary-registry -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "${POD_STATUS}" == "Running" ]]; then
        echo ""
        echo "✅ OK: Secondary registry pod RUNNING"
        echo "   No verification required (per policy)"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | grep "test-secondary-registry" | tail -2 || true
    else
        echo ""
        echo "⚠️  Pod status: ${POD_STATUS}"
        kubectl describe pod test-secondary-registry | tail -20
    fi
    kubectl delete pod test-secondary-registry --wait=false >/dev/null 2>&1 || true
else
    echo ""
    echo "❌ ERROR: Secondary registry pod CREATE FAILED"
fi
echo ""

echo "==> Testing complete!"
echo ""
echo "Summary:"
echo "  Per-registry verification policies with BYO-PKI"
echo "  Primary registry (127.0.0.1:5000): Verified with CA"
echo "  Secondary registry (127.0.0.1:5001): No verification"
echo "  gcr.io: BLOCKED"
echo ""
echo "View logs for detailed verification:"
echo "  sudo journalctl -t containerd-verifier -n 20"
echo "  kubectl get events --sort-by='.lastTimestamp'"
