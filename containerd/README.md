# Containerd Transfer Service Signature Verification

<!-- markdownlint-configure-file { "MD013": { "tables": false } } -->

Runtime signature verification using containerd 2.1+ Transfer Service with
BYO-PKI certificates.

## ⚠️ Limitation

**Transfer Service verifiers only run on registry pulls, NOT on cached images.**

This means:

- Cached images bypass verification
- Pre-loaded images run without checks
- `ctr image import` bypasses verification

**For production:** Use admission controllers (Kyverno, Ratify) as primary
control. Transfer Service is defense-in-depth only.

## Requirements

- **containerd 2.1+** ([Transfer Service
  API](https://github.com/containerd/containerd/blob/main/docs/transfer.md))
- Ubuntu 24.04 VM with sudo

## Quick Start

```bash
make setup    # Install containerd 2.1+, k8s, docker, cosign (requires reboot)
# <reboot>
make run      # Installs verifier, initializes k8s, signs images, tests
```

## How It Works

Containerd config (`/etc/containerd/config.toml`):

```toml
version = 3

[plugins.'io.containerd.transfer.v1.local']
  [[plugins.'io.containerd.transfer.v1.local'.unpack_config]]
    platform = 'linux/amd64'
    snapshotter = 'overlayfs'
    [plugins.'io.containerd.transfer.v1.local'.unpack_config.verifier]
      type = 'command'
      command = '/opt/containerd/image-verifier/bin/verifier'
      args = ['-name', '{src.name}', '-digest', '{src.digest}']
```

Verifier policy config (`/etc/containerd/image-verifier.conf`):

```bash
# Per-registry policies (regex patterns supported)
REGISTRY_POLICY_PRIMARY=127\.0\.0\.1:5000|/etc/containerd/certs/registry-primary-ca.crt
REGISTRY_POLICY_SECONDARY=127\.0\.0\.1:5001|ALLOW
REGISTRY_POLICY_GCR=gcr\.io|BLOCK

# Default action for unknown registries
VERIFY_DEFAULT_ACTION=allow
```

Policy enforces **4 scenarios** (same as CRI-O):

- `127.0.0.1:5000`: VERIFY with BYO-PKI
- `127.0.0.1:5001`: ALLOW without verification
- `gcr.io`: BLOCK
- Default: ALLOW

Verifier is a bash script that validates signatures using
[sigstore/cosign](https://github.com/sigstore/cosign).

## Testing

```bash
kubectl apply -f manifests/signed-pod.yaml              # → Running
kubectl apply -f manifests/unsigned-pod.yaml            # → ImagePullBackOff
kubectl apply -f manifests/gcr-blocked-pod.yaml         # → ImagePullBackOff
kubectl apply -f manifests/secondary-registry-pod.yaml  # → Running (no verification)
```

## Key Differences from CRI-O

| Feature | CRI-O | Containerd Transfer Service |
|---------|-------|----------------------------|
| Verification trigger | Every image use | Registry pull only |
| Cache bypass | ❌ No | ✅ Yes (cached images skip verification) |
| Config location | `/etc/containers/policy.json` | `/etc/containerd/image-verifier.conf` |
| Implementation | Native `containers/image` | External verifier plugin |
| Production use | ✅ Primary control | ⚠️ Defense-in-depth only |

## References

- [containerd Transfer
  Service](https://github.com/containerd/containerd/blob/main/docs/transfer.md)
- [Transfer Service limitation
  discussion](https://github.com/containerd/containerd/issues/10768)

<!-- cSpell:ignore kyverno,sigstore -->
