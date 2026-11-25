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

echo "Registry verification policies (/etc/containerd/image-verifier.conf):"
grep -E '^(REGISTRY_POLICY_|VERIFY_DEFAULT_ACTION)' /etc/containerd/image-verifier.conf | sed 's/^/  /'
echo ""

# verify_pod <test> <pod> <image> <verdict> [digest]: the image is dropped
# from the node first, so the pod pulls it, and the verifier must log its
# verdict for that image: PASSED or FAILED on exactly that digest, a FAILED
# for want of a signature, or the ALLOW or BLOCK of the registry policy. The
# pod runs on PASSED and ALLOW, and is blocked otherwise.
verify_pod() {
    local test="$1" pod="$2" image="$3" verdict="$4" digest="${5:-}" since phase expected
    case "${verdict}" in
    PASSED) expected="PASSED for ${image%@*}@${digest}" ;;
    FAILED) expected="FAILED for ${image%@*}@${digest}: error during command execution: no signatures found" ;;
    *) expected="POLICY ACTION: ${verdict} - " ;;
    esac
    echo "==> Test ${test}: ${image} (should be ${verdict}${digest:+ on ${digest}})"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    sudo ctr -n k8s.io images rm "${image}" >/dev/null 2>&1 || true
    kubectl run "${pod}" --image="${image}" --restart=Never -- sleep 3600 >/dev/null
    if [[ "${verdict}" == PASSED || "${verdict}" == ALLOW ]]; then
        kubectl wait --for=condition=Ready "pod/${pod}" --timeout=60s >/dev/null 2>&1 ||
            fail "ERROR: ${pod} not running"
    else
        sleep 20
        phase="$(kubectl get pod "${pod}" -o jsonpath='{.status.phase}')"
        [[ "${phase}" != Running ]] || fail "ERROR: ${pod} running"
    fi
    if sudo journalctl -t containerd-verifier --since "${since}" -o cat |
        grep -F "${image%@*}" | grep -qF "${expected}"; then
        echo "[OK] OK: verifier ${expected}"
    else
        fail "ERROR: no verifier log line: ${expected}"
        sudo journalctl -t containerd-verifier --since "${since}" -o cat | tail -5
        kubectl describe pod "${pod}" | tail -5
    fi
    kubectl delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
    echo ""
}

# Tests 1 to 6: legacy signatures on 127.0.0.1:5000 against the root CA, the
# registry policy keywords, and Sigstore bundles on 127.0.0.1:5002 against a
# trusted root.
resolve() { oras resolve --plain-http "$1"; }
PRIMARY=127.0.0.1:5000
BUNDLE=127.0.0.1:5002
SIGNED="$(resolve "${PRIMARY}/alpine:3.20.3")"
UNSIGNED="$(resolve "${PRIMARY}/alpine:unsigned")"
BUNDLE_SIGNED="$(resolve "${BUNDLE}/alpine:3.20.3")"
BUNDLE_UNSIGNED="$(resolve "${BUNDLE}/alpine:unsigned")"
verify_pod 1 test-signed "${PRIMARY}/alpine:3.20.3" PASSED "${SIGNED}"
verify_pod 2 test-unsigned "${PRIMARY}/alpine:unsigned" FAILED "${UNSIGNED}"
verify_pod 3 test-gcr-blocked gcr.io/google-containers/pause:3.2 BLOCK
verify_pod 4 test-secondary-registry 127.0.0.1:5001/nginx:alpine ALLOW
verify_pod 5 test-bundle "${BUNDLE}/alpine:3.20.3" PASSED "${BUNDLE_SIGNED}"
verify_pod 6 test-bundle-unsigned "${BUNDLE}/alpine:unsigned" FAILED "${BUNDLE_UNSIGNED}"

# Tests 7 to 11: the production shape from ../cosign-v4-pre v4-multiarch on
# 127.0.0.1:5004: RSA 4096 leaf, leaf-only bundle with signed timestamp,
# signed without cosign.
V4=127.0.0.1:5004
INDEX="$(oras resolve --plain-http "${V4}/multi/index-only:3.20.3")"
AMD64="$(oras manifest fetch --plain-http "${V4}/multi/index-only@${INDEX}" |
    jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest')"

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

# Test 13: the timestamped bundle of ../cosign-v4-pre v4-leaf-expiry, whose
# leaf has expired, is verified at its signing time, as Kyverno does
# (../kyverno/bundle-expiry.mk).
EXPIRED="$(oras resolve --plain-http "${V4}/expiry/tsa:3.20.3")"
verify_pod 13 test-v4-leaf-expired "${V4}/expiry/tsa:3.20.3" PASSED "${EXPIRED}"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "==> ${FAILURES} check(s) FAILED"
    exit 1
fi
echo "==> Testing complete!"
echo ""
echo "View logs for detailed verification:"
echo "  sudo journalctl -t containerd-verifier -n 20"
echo "  kubectl get events --sort-by='.lastTimestamp'"
