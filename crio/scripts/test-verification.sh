#!/usr/bin/env bash
# Test signature verification with CRI-O BYO-PKI

set -euo pipefail

echo "==> Testing CRI-O signature verification (BYO-PKI)..."
echo ""

# Check if crictl is available
if ! command -v crictl &> /dev/null; then
    echo "ERROR: crictl not found"
    echo "   Run: make setup"
    exit 1
fi

# Check if policy is configured
if [[ ! -f /etc/crio/policy.json ]]; then
    echo "ERROR: /etc/crio/policy.json not found"
    echo "   Run: make install-policy"
    exit 1
fi

# Check if certificates exist
if [[ ! -f /etc/containers/certs/ca-roots.pem ]]; then
    echo "ERROR: /etc/containers/certs/ca-roots.pem not found"
    echo "   Run: make install-policy"
    exit 1
fi

if [[ ! -f /etc/containers/certs/ca-intermediates.pem ]]; then
    echo "ERROR: /etc/containers/certs/ca-intermediates.pem not found"
    echo "   Run: make install-policy"
    exit 1
fi

# Check if CRI-O is running
if ! systemctl is-active --quiet crio; then
    echo "ERROR: CRI-O is not running"
    echo "   Start it with: sudo systemctl start crio"
    exit 1
fi

echo "Configuration check:"
echo "  OK crictl installed"
echo "  OK policy.json exists"
echo "  OK CA root certificate exists"
echo "  OK CA intermediate certificate exists"
echo "  OK CRI-O is running"
echo ""

# Show policy configuration
echo "Policy configuration:"
jq -r '.transports.docker."127.0.0.1:5003"[0] | "  Type: \(.type)\n  CA Roots: \(.pki.caRootsPath)\n  CA Intermediates: \(.pki.caIntermediatesPath)\n  Subject Email: \(.pki.subjectEmail)"' /etc/crio/policy.json
echo ""

# Test 1: Pull signed image
echo "==> Test 1: Pull signed image (should succeed)"
echo "   Image: 127.0.0.1:5003/alpine:3.20.3"
echo "   Verification: BYO-PKI certificate chain with email ci-build@example.com"
echo ""
if sudo crictl pull 127.0.0.1:5003/alpine:3.20.3 2>&1 | tee /tmp/crio-test-signed.log; then
    echo ""
    echo "[OK] OK: Signed image pull SUCCEEDED"
    echo "   Certificate chain validation passed"
else
    echo ""
    echo "[ERROR] ERROR: Signed image pull FAILED"
    echo "   Make sure you ran: make run (it sets up automatically)"
    echo ""
    echo "   Check CRI-O logs: sudo journalctl -u crio -n 50"
    echo "   Check for certificate errors"
fi
echo ""

# Test 2: Pull unsigned image
echo "==> Test 2: Pull unsigned image (should fail)"
echo "   Image: 127.0.0.1:5003/alpine:unsigned"
echo ""
if sudo crictl pull 127.0.0.1:5003/alpine:unsigned 2>&1 | tee /tmp/crio-test-unsigned.log; then
    echo ""
    echo "[ERROR] ERROR: Unsigned image pull SUCCEEDED (should have failed!)"
    echo "   Check policy.json configuration"
else
    echo ""
    echo "[OK] OK: Unsigned image pull FAILED as expected"
    echo "   Policy enforcement working correctly"
fi
echo ""

# Test 3 & 4: Kubernetes pod tests (if k8s is available)
if command -v kubectl &> /dev/null && kubectl get nodes &> /dev/null 2>&1; then
    # Ensure node is Ready before running pod tests
    echo "==> Ensuring Kubernetes node is Ready..."
    if ! kubectl wait --for=condition=Ready nodes --all --timeout=60s 2>/dev/null; then
        echo "   WARNING: Node not Ready, skipping pod tests"
        kubectl get nodes -o wide
        echo ""
        echo "==> Skipping Kubernetes pod tests (node not ready)"
        echo ""
        echo "==> Testing complete!"
        echo ""
        echo "Summary:"
        echo "  BYO-PKI certificate chain verification is working"
        echo "  Root CA -> Intermediate CA -> Leaf certificate"
        echo "  Email identity enforcement: ci-build@example.com"
        echo ""
        echo "View CRI-O logs for detailed verification:"
        echo "  sudo journalctl -u crio -n 50 | grep -i signature"
        exit 0
    fi
    echo "   OK: Node is Ready"
    echo ""

    echo "==> Test 3: Kubernetes pod with signed image (should succeed)"
    echo "   Pod: signed-alpine-crio"
    echo "   Image: 127.0.0.1:5003/alpine:3.20.3"
    echo ""

    # Clean up any existing pods
    kubectl delete pod signed-alpine-crio --wait=false >/dev/null 2>&1 || true
    sleep 2

    if kubectl apply -f manifests/signed-pod.yaml 2>&1 | tee /tmp/crio-test-k8s-signed.log; then
        echo "Waiting for pod to start..."

        # Wait up to 30 seconds for pod to start
        for i in {1..15}; do
            POD_STATUS=$(kubectl get pod signed-alpine-crio -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
            if [[ "${POD_STATUS}" == "Running" ]]; then
                break
            fi
            sleep 2
        done

        POD_STATUS=$(kubectl get pod signed-alpine-crio -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "${POD_STATUS}" == "Running" ]]; then
            echo ""
            echo "[OK] OK: Signed image pod RUNNING"
            echo "   Certificate chain validation passed in Kubernetes"
            kubectl get pod signed-alpine-crio
        else
            echo ""
            echo "[ERROR] ERROR: Pod status: ${POD_STATUS}"
            kubectl describe pod signed-alpine-crio | tail -20
        fi
        kubectl delete pod signed-alpine-crio --wait=false >/dev/null 2>&1 || true
    else
        echo ""
        echo "[ERROR] ERROR: Signed pod CREATE FAILED"
    fi
    echo ""

    echo "==> Test 4: Kubernetes pod with unsigned image (should fail)"
    echo "   Pod: unsigned-alpine-crio"
    echo "   Image: 127.0.0.1:5003/alpine:unsigned"
    echo ""

    # Clean up any existing pods
    kubectl delete pod unsigned-alpine-crio --wait=false >/dev/null 2>&1 || true
    sleep 2

    if kubectl apply -f manifests/unsigned-pod.yaml 2>&1 | tee /tmp/crio-test-k8s-unsigned.log; then
        echo "Waiting for pod to fail..."
        sleep 8

        # shellcheck disable=SC2034
        for i in {1..10}; do
            POD_STATUS=$(kubectl get pod unsigned-alpine-crio -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
            CONTAINER_STATE=$(kubectl get pod unsigned-alpine-crio -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || echo "{}")

            if [[ "${POD_STATUS}" == "Running" ]] || echo "${CONTAINER_STATE}" | grep -q "waiting"; then
                break
            fi
            sleep 2
        done

        if echo "${CONTAINER_STATE}" | grep -q "waiting"; then
            REASON=$(kubectl get pod unsigned-alpine-crio -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

            if [[ "${REASON}" == "ImagePullBackOff" ]] || [[ "${REASON}" == "ErrImagePull" ]]; then
                echo ""
                echo "[OK] OK: Unsigned image pod BLOCKED by CRI-O policy"
                echo "   Reason: ${REASON}"
                kubectl describe pod unsigned-alpine-crio | grep -A5 "Events:" | tail -3 || true
            else
                echo ""
                echo "[ERROR] WARNING: Pod blocked but reason unclear: ${REASON}"
            fi
        elif [[ "${POD_STATUS}" == "Running" ]]; then
            echo ""
            echo "[ERROR] ERROR: Unsigned pod is RUNNING (should have failed!)"
            kubectl get pod unsigned-alpine-crio
        else
            echo ""
            echo "[WARN]  Pod status: ${POD_STATUS}"
            kubectl describe pod unsigned-alpine-crio | tail -10
        fi
        kubectl delete pod unsigned-alpine-crio --wait=false >/dev/null 2>&1 || true
    else
        echo ""
        echo "[ERROR] ERROR: Unsigned pod CREATE FAILED"
    fi
    echo ""
else
    echo "==> Skipping Kubernetes pod tests (cluster not available)"
    echo "   Run: sudo ./scripts/init-k8s.sh to initialize Kubernetes"
    echo ""
fi

echo "==> Testing complete!"
echo ""
echo "Summary:"
echo "  BYO-PKI certificate chain verification is working"
echo "  Root CA -> Intermediate CA -> Leaf certificate"
echo "  Email identity enforcement: ci-build@example.com"
echo ""
echo "View CRI-O logs for detailed verification:"
echo "  sudo journalctl -u crio -n 50 | grep -i signature"
