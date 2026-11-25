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
# verdict for that image: PASSED or FAILED on exactly that digest, FAILED for
# want of a legacy signature, NOBUNDLE for want of a bundle, MISBOUND for a
# bundle of another digest, LEAF for a leaf the trusted root does not cover at
# the signing time, CHAIN for a bundle bringing an intermediate the trusted
# root lacks, IDENTITY for another signer than the policy pins, or the ALLOW
# or BLOCK of the registry policy. The pod runs on PASSED and ALLOW, and is
# blocked otherwise.
verify_pod() {
    local test="$1" pod="$2" image="$3" verdict="$4" digest="${5:-}" since phase expected
    case "${verdict}" in
    PASSED) expected="PASSED for ${image%@*}@${digest}" ;;
    FAILED) expected="FAILED for ${image%@*}@${digest}: error during command execution: no signatures found" ;;
    NOBUNDLE) expected="FAILED for ${image%@*}@${digest}: no Sigstore bundle" ;;
    LEAF) expected="FAILED for ${image%@*}@${digest}: error during command execution: failed to verify leaf certificate: leaf certificate verification failed" ;;
    IDENTITY) expected="FAILED for ${image%@*}@${digest}: error during command execution: failed to verify certificate identity: no matching CertificateIdentity found" ;;
    CHAIN) expected="FAILED for ${image%@*}@${digest}: error during command execution: --trusted-root only supported with --new-bundle-format" ;;
    MISBOUND) expected="FAILED for ${image%@*}@${digest}: error during command execution: failed to verify signature: provided artifact digest does not match any digest in statement" ;;
    *) expected="POLICY ACTION: ${verdict} - " ;;
    esac
    echo "==> Test ${test}: ${image} (should be ${verdict}${digest:+ on ${digest}})"
    kubectl delete pod "${pod}" --ignore-not-found --wait >/dev/null
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
verify_pod 6 test-bundle-unsigned "${BUNDLE}/alpine:unsigned" NOBUNDLE "${BUNDLE_UNSIGNED}"

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
verify_pod 9 test-v4-platform-tag "${V4}/multi/platform-only:3.20.3" NOBUNDLE "${INDEX}"
verify_pod 10 test-v4-index-amd64 "${V4}/multi/index-only@${AMD64}" NOBUNDLE "${AMD64}"
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
kubectl delete pod test-local-pull --ignore-not-found --wait >/dev/null
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

# Test 14: ../cosign-v4-pre v4-legacy-fallback, a legacy signature by the same
# PKI and no bundle, which cosign verify 3.x accepts under the bundle flags.
# The verifier verifies bundles only, and refuses it.
LEGACY="$(oras resolve --plain-http "${V4}/legacy/alpine:3.20.3")"
verify_pod 14 test-v4-legacy "${V4}/legacy/alpine:3.20.3" NOBUNDLE "${LEGACY}"

# Test 15: a bundle present but of another digest: the production bundle of
# the relocated image, attached to alpine:3.19 in the same registry. The
# verifier finds it, and refuses it on the signed digest.
MISBOUND_IMAGE="${V4}/misbound/alpine:3.19"
docker pull -q alpine:3.19 >/dev/null
docker tag alpine:3.19 "${MISBOUND_IMAGE}"
docker push -q "${MISBOUND_IMAGE}" >/dev/null
MISBOUND="$(oras resolve --plain-http "${MISBOUND_IMAGE}")"
BUNDLE_TYPE=application/vnd.dev.sigstore.bundle.v0.3+json
WORK="$(mktemp -d)"
manifest="$(oras discover --plain-http --artifact-type "${BUNDLE_TYPE}" --format json \
    "${V4}/relocated/alpine:3.20.3" | jq -r '.referrers[0].digest')"
layer="$(oras manifest fetch --plain-http "${V4}/relocated/alpine@${manifest}" | jq -r '.layers[0].digest')"
oras blob fetch --plain-http --output "${WORK}/bundle.json" "${V4}/relocated/alpine@${layer}"
(cd "${WORK}" && oras attach --plain-http --artifact-type "${BUNDLE_TYPE}" \
    "${V4}/misbound/alpine@${MISBOUND}" "bundle.json:${BUNDLE_TYPE}" >/dev/null)
rm -- "${WORK}/bundle.json"
rmdir -- "${WORK}"
verify_pod 15 test-v4-misbound "${MISBOUND_IMAGE}" MISBOUND "${MISBOUND}"

# Tests 16 to 20, with DEVCERTS: ../cosign-v4-pre v4-devcerts, the EPPKI C1 dev
# kit's container certificates, against its root and SubCA_C1_dev_2. The one
# its CRL revokes passes, as no CRL is read. The trusted root names its
# intermediate, so the verifier takes none from a bundle: test 20, the revoked
# SubCA_C1_dev_5 brought in the bundle, is refused, with a misleading error.
# The policy pins the kit's SAN. The kit has no leaf of SubCA_C1_dev_2 with
# another SAN, nor the SubCA's key to issue one, so test 21 turns it around:
# devcerts/other-san, the valid image under a policy pinning another SAN, is
# refused.
if [[ -n "${DEVCERTS:-}" ]]; then
    [[ -f /etc/containerd/certs/registry-devcerts-trusted-root.json ]] ||
        fail "ERROR: DEVCERTS set, but the dev kit's trusted root is not installed"
    DEVKIT="$(oras resolve --plain-http "${V4}/devcerts/ok:3.20.3")"
    verify_pod 16 test-dev-ok "${V4}/devcerts/ok:3.20.3" PASSED "${DEVKIT}"
    verify_pod 17 test-dev-revoked "${V4}/devcerts/revoked:3.20.3" PASSED "${DEVKIT}"
    verify_pod 18 test-dev-expired "${V4}/devcerts/expired:3.20.3" LEAF "${DEVKIT}"
    verify_pod 19 test-dev-revoked-ca "${V4}/devcerts/revoked-ca:3.20.3" LEAF "${DEVKIT}"
    verify_pod 20 test-dev-revoked-ca-chain "${V4}/devcerts/revoked-ca-chain:3.20.3" CHAIN "${DEVKIT}"
    verify_pod 21 test-dev-other-san "${V4}/devcerts/other-san:3.20.3" IDENTITY "${DEVKIT}"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "==> ${FAILURES} check(s) FAILED"
    exit 1
fi
echo "==> Testing complete!"
echo ""
echo "View logs for detailed verification:"
echo "  sudo journalctl -t containerd-verifier -n 20"
echo "  kubectl get events --sort-by='.lastTimestamp'"
