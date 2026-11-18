#!/usr/bin/env bash
# Test containerd Transfer Service signature verification with per-registry policies

set -euo pipefail

# Every [ERROR] counts; the script exits non-zero if any occurred.
FAILURES=0
fail() {
    FAILURES=$((FAILURES + 1))
    echo "[ERROR] $*"
}

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
        echo "[OK] OK: Signed image pod RUNNING"
        echo "   Certificate chain validation passed"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -3 || true
    else
        echo ""
        fail "ERROR: Pod status: ${POD_STATUS}"
        kubectl describe pod test-signed | tail -30
    fi
    kubectl delete pod test-signed --wait=false >/dev/null 2>&1 || true
else
    echo ""
    fail "ERROR: Signed image pod CREATE FAILED"
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
            echo "[OK] OK: Unsigned image pod BLOCKED by Transfer Service verifier"
            echo "   Reason: ${REASON}"
            sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -3 || true
        else
            echo ""
            echo "[WARN]  Pod waiting but not due to verifier: ${REASON}    "
            kubectl describe pod test-unsigned | tail -20
        fi
    elif [[ "${POD_STATUS}" == "Running" ]]; then
        echo ""
        fail "ERROR: Unsigned image pod RUNNING"
        echo "   Verifier did NOT block this!"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -5 || true
    else
        echo ""
        echo "[WARN]  Pod status: ${POD_STATUS}"
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
            echo "[OK] OK: gcr.io image BLOCKED by policy"
            echo "   Reason: ${REASON}"
            sudo journalctl -t containerd-verifier --since '30 sec ago' | grep -A2 "gcr.io" | tail -3 || true
        else
            echo ""
            echo "[WARN]  Pod waiting but not due to policy: ${REASON}"
            kubectl describe pod test-gcr-blocked | tail -20
        fi
    elif [[ "${POD_STATUS}" == "Running" ]]; then
        echo ""
        fail "ERROR: gcr.io image pod RUNNING"
        echo "   Policy did NOT block this!"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | tail -5 || true
    else
        echo ""
        echo "[WARN]  Pod status: ${POD_STATUS}"
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
        echo "[OK] OK: Secondary registry pod RUNNING"
        echo "   No verification required (per policy)"
        sudo journalctl -t containerd-verifier --since '30 sec ago' | grep "test-secondary-registry" | tail -2 || true
    else
        echo ""
        echo "[WARN]  Pod status: ${POD_STATUS}"
        kubectl describe pod test-secondary-registry | tail -20
    fi
    kubectl delete pod test-secondary-registry --wait=false >/dev/null 2>&1 || true
else
    echo ""
    fail "ERROR: Secondary registry pod CREATE FAILED"
fi
echo ""

# Tests 5 and 6: Sigstore bundles (cosign v4 format) against a trusted root.
# A blocked pull must be the verifier's doing, so test 6 also requires its
# FAIL log line for that image.
echo "==> Test 5: Bundle registry with bundle-signed image (should SUCCEED)"
echo "   Image: 127.0.0.1:5002/alpine:3.20.3"
kubectl run test-bundle --image=127.0.0.1:5002/alpine:3.20.3 --restart=Never -- sleep 3600 >/dev/null
if kubectl wait --for=condition=Ready pod/test-bundle --timeout=60s >/dev/null 2>&1; then
    echo "[OK] OK: Bundle-signed image pod RUNNING"
else
    fail "ERROR: Bundle-signed image pod not running"
    kubectl describe pod test-bundle | tail -10
fi
sudo journalctl -t containerd-verifier --since '90 sec ago' | grep '5002/alpine:3.20.3' | tail -2 || true
kubectl delete pod test-bundle --wait=false >/dev/null 2>&1 || true
echo ""

echo "==> Test 6: Bundle registry with unsigned image (should FAIL)"
echo "   Image: 127.0.0.1:5002/alpine:unsigned"
kubectl run test-bundle-unsigned --image=127.0.0.1:5002/alpine:unsigned --restart=Never -- sleep 3600 >/dev/null
sleep 20
POD_STATUS=$(kubectl get pod test-bundle-unsigned -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "${POD_STATUS}" == "Running" ]]; then
    fail "ERROR: Unsigned image pod RUNNING from the bundle registry"
elif sudo journalctl -t containerd-verifier --since '60 sec ago' |
    grep -q 'FAILED for 127.0.0.1:5002/alpine:unsigned'; then
    echo "[OK] OK: Unsigned image pod BLOCKED by Transfer Service verifier"
else
    fail "ERROR: Unsigned image not running, but the verifier did not block it"
    kubectl describe pod test-bundle-unsigned | tail -10
fi
kubectl delete pod test-bundle-unsigned --wait=false >/dev/null 2>&1 || true
echo ""

# Tests 7 to 11: the production shape from ../cosign-v4-pre v4-multiarch on
# 127.0.0.1:5004: RSA 4096 leaf, leaf-only bundle with signed timestamp,
# signed without cosign. Each image is dropped from the node first, so the pod
# pulls it, and the verifier must log its verdict on the expected digest.
V4=127.0.0.1:5004
INDEX="$(oras resolve --plain-http "${V4}/multi/index-only:3.20.3")"
AMD64="$(oras manifest fetch --plain-http "${V4}/multi/index-only@${INDEX}" |
    jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest')"

# verify_pod <test> <pod> <image> <PASSED|FAILED> <digest>: the pod runs, or
# is blocked, and the verifier logged that verdict on exactly that digest; a
# FAILED must be for want of a bundle on it.
verify_pod() {
    local test="$1" pod="$2" image="$3" verdict="$4" digest="$5" since phase expected
    echo "==> Test ${test}: ${image} (should be ${verdict} on ${digest})"
    expected="${verdict} for ${image%@*}@${digest}"
    [[ "${verdict}" == PASSED ]] ||
        expected="${expected}: error during command execution: no signatures found"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    sudo ctr -n k8s.io images rm "${image}" >/dev/null 2>&1 || true
    kubectl run "${pod}" --image="${image}" --restart=Never -- sleep 3600 >/dev/null
    if [[ "${verdict}" == PASSED ]]; then
        kubectl wait --for=condition=Ready "pod/${pod}" --timeout=60s >/dev/null 2>&1 ||
            fail "ERROR: ${pod} not running"
    else
        sleep 20
        phase="$(kubectl get pod "${pod}" -o jsonpath='{.status.phase}')"
        [[ "${phase}" != Running ]] || fail "ERROR: ${pod} running"
    fi
    if sudo journalctl -t containerd-verifier --since "${since}" -o cat | grep -qF "${expected}"; then
        echo "[OK] OK: verifier ${expected}"
    else
        fail "ERROR: no verifier log line: ${expected}"
        sudo journalctl -t containerd-verifier --since "${since}" -o cat | tail -5
    fi
    kubectl delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
    echo ""
}

verify_pod 7 test-v4-rsa "${V4}/relocated/alpine:3.20.3" PASSED "${AMD64}"
# Verified is the digest the pod names: for a tag, the index.
verify_pod 8 test-v4-index-tag "${V4}/multi/index-only:3.20.3" PASSED "${INDEX}"
verify_pod 9 test-v4-platform-tag "${V4}/multi/platform-only:3.20.3" FAILED "${INDEX}"
verify_pod 10 test-v4-index-amd64 "${V4}/multi/index-only@${AMD64}" FAILED "${AMD64}"
verify_pod 11 test-v4-platform-amd64 "${V4}/multi/platform-only@${AMD64}" PASSED "${AMD64}"

# Test 12: the CRI local pull path, use_local_image_pull = true, as on a node
# that decrypts images, does not go through the Transfer Service, so the
# verifier is never invoked: an unsigned image from the verified bundle
# registry runs, and the verifier logs nothing. The setting is undone after.
echo "==> Test 12: use_local_image_pull = true skips the verifier (unsigned image RUNS)"
LOCAL_IMAGE=127.0.0.1:5002/alpine:unsigned-local
docker pull -q alpine:3.19 >/dev/null
docker tag alpine:3.19 "${LOCAL_IMAGE}"
docker push -q "${LOCAL_IMAGE}" >/dev/null
sudo ctr -n k8s.io images rm "${LOCAL_IMAGE}" >/dev/null 2>&1 || true
sudo sed -i 's/use_local_image_pull = false/use_local_image_pull = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
if ! sudo containerd config dump 2>/dev/null | grep -q 'use_local_image_pull = true'; then
    fail "ERROR: use_local_image_pull = true not in effect"
fi
since="$(date '+%Y-%m-%d %H:%M:%S')"
kubectl run test-local-pull --image="${LOCAL_IMAGE}" --restart=Never -- sleep 3600 >/dev/null
if kubectl wait --for=condition=Ready pod/test-local-pull --timeout=120s >/dev/null 2>&1; then
    echo "[OK] OK: unsigned image RUNNING on the local pull path"
else
    fail "ERROR: unsigned image not running on the local pull path"
    kubectl describe pod test-local-pull | tail -10
fi
verifier_log="$(sudo journalctl -t containerd-verifier --since "${since}" -o cat)"
if [[ -z "${verifier_log}" ]]; then
    echo "[OK] OK: verifier not invoked"
else
    fail "ERROR: verifier invoked on the local pull path: ${verifier_log}"
fi
kubectl delete pod test-local-pull --wait=false >/dev/null 2>&1 || true
sudo ctr -n k8s.io images rm "${LOCAL_IMAGE}" >/dev/null 2>&1 || true
sudo sed -i 's/use_local_image_pull = true/use_local_image_pull = false/' /etc/containerd/config.toml
sudo systemctl restart containerd
echo ""

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "==> ${FAILURES} check(s) FAILED"
    exit 1
fi
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
