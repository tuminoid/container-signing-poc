# CRI-O Runtime Signature Verification POC

This POC demonstrates container signature verification at the CRI-O runtime level using its **built-in signature verification** support.

## Overview

CRI-O has native support for signature verification through the `containers/image` library. It uses a simple policy file (`/etc/containers/policy.json`) to define verification rules.

### Architecture

```
Kubernetes → CRI-O → containers/image library → Policy Check → Registry
                           ↓
                    Allow or Reject based on signature
```

## Prerequisites

- Ubuntu 24.04 VM (or compatible)
- Root/sudo access

**IMPORTANT**: This POC must be run on a dedicated VM, not on your laptop. The setup script installs packages and modifies system files.

## Quick Start

This POC is **completely standalone** - all dependencies are installed and generated automatically.

### 1. Initial Setup (One-time)

```bash
make setup
```

This will:
- Ask for confirmation (VM check)
- Install CRI-O, docker, cosign, crictl
- Configure CRI-O
- **Requires sudo** (will prompt during script execution)
- **Requires reboot after completion**

### 2. Reboot

```bash
sudo reboot
```

### 3. Run Tests

```bash
make test
```

On first run, this will:
- Start local registry
- Generate cosign keypair
- Sign test images
- Install signature policy (with sudo)
- Run verification tests

### 4. Iterate

```bash
make test && make clean
```

Run this as many times as needed to test changes.
# 1. Start local registry
make setup-registry

# 2. Generate cosign keys
make gen-keys

# 3. Sign test image
make sign-image

# 4. Install policy and keys (uses sudo internally)
make install-policy

# 5. Test verification
make test

# 6. Test with Kubernetes pods (optional)
make test-pods
```

### Check Status

```bash
make status
```

### Cleanup

```bash
make clean           # Remove test pods
make clean-all       # Remove everything (policy, registry, keys)
```

## How It Works

### Policy Configuration

The policy file (`config/policy.json`) defines rules for each registry:

```json
{
  "default": [{"type": "reject"}],  // Reject by default
  "transports": {
    "docker": {
      "127.0.0.1:5003": [
        {
          "type": "sigstoreSigned",              // Use sigstore/cosign signatures
          "keyPath": "/etc/containers/keys/cosign.pub",
          "signedIdentity": {"type": "matchRepository"}
        }
      ],
      "registry.k8s.io": [
        {"type": "insecureAcceptAnything"}      // Allow system images
      ]
    }
  }
}
```

**Policy Types:**
- `reject` - Reject all images
- `insecureAcceptAnything` - Accept without verification (not recommended for production)
- `sigstoreSigned` - Verify using Cosign/Sigstore signatures
- `signedBy` - Verify using GPG signatures

### Registry Configuration

The registries.d configuration (`config/registries.d/default.yaml`) tells CRI-O where to find signatures:

```yaml
docker:
  127.0.0.1:5003:
    sigstore: http://127.0.0.1:5003  # Signatures stored in same registry
```

### Verification Flow

1. CRI-O receives image pull request
2. Checks `/etc/containers/policy.json` for matching rule
3. If `sigstoreSigned`, fetches signature from registry
4. Verifies signature with public key
5. Allows pull if valid, rejects if invalid

## Testing

### Manual Testing with crictl

```bash
# Test signed image (should succeed)
sudo crictl pull 127.0.0.1:5003/alpine:3.20.3

# Test unsigned image (should fail)
sudo crictl pull alpine:latest
```

### Pod Testing

If you have Kubernetes with CRI-O:

```bash
# Deploy signed pod (should work)
kubectl apply -f manifests/signed-pod.yaml

# Deploy unsigned pod (should fail)
kubectl apply -f manifests/unsigned-pod.yaml

# Check results
kubectl get pods -l test=crio-verification
kubectl describe pod unsigned-alpine-crio  # Should show signature verification error
```

### Check Logs

```bash
# CRI-O logs
sudo journalctl -u crio -n 50 -f

# Look for signature verification messages
sudo journalctl -u crio | grep -i signature
```

## Troubleshooting

### Image pull fails with "signature verification failed"

**Good!** This means verification is working. Check:
1. Is the image actually signed?
2. Is the signature in the registry?
3. Is the public key correct?

### All images are rejected

Check policy file:
```bash
sudo cat /etc/containers/policy.json
```

Make sure system registries like `registry.k8s.io` are allowed.

### Signatures not found

Check registries.d configuration:
```bash
sudo cat /etc/containers/registries.d/default.yaml
```

Verify the sigstore URL is correct.

### Permission errors

Make sure files have correct permissions:
```bash
sudo chmod 644 /etc/containers/policy.json
sudo chmod 644 /etc/containers/keys/cosign.pub
```

## Policy Examples

### Allow specific registry with verification

```json
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "myregistry.com": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/containers/keys/prod.pub"
        }
      ]
    }
  }
}
```

### Multiple signature verification

```json
{
  "docker": {
    "myregistry.com/critical/*": [
      {
        "type": "sigstoreSigned",
        "keyPath": "/etc/containers/keys/security-team.pub"
      },
      {
        "type": "sigstoreSigned",
        "keyPath": "/etc/containers/keys/release-team.pub"
      }
    ]
  }
}
```

## Production Recommendations

1. **Default Reject**: Always start with `"default": [{"type": "reject"}]`
2. **Allowlist Registries**: Explicitly allow only trusted registries
3. **System Images**: Allow kubernetes system images without verification
4. **Key Management**: Protect public keys, rotate regularly
5. **Monitoring**: Monitor verification failures
6. **Testing**: Test policies in staging before production

## Comparison with Containerd

| Feature | CRI-O | Containerd |
|---------|-------|------------|
| Built-in support | ✅ Yes | ❌ No |
| Configuration | Simple JSON | Complex hooks |
| Setup time | 5 minutes | 30+ minutes |
| Production ready | ✅ Yes | Custom solution |
| Maintenance | Low | Medium |
| Requires VM | Yes | Optional (Kind works) |

## Advantages of CRI-O

1. **Native Support**: No custom code needed
2. **Simple Configuration**: Single policy file
3. **Production Ready**: Well-tested and maintained
4. **Multiple Signature Types**: Supports GPG, Cosign, Notation
5. **Granular Policies**: Per-registry, per-namespace rules
6. **Performance**: Optimized verification path

## Next Steps

1. Test with your own signed images
2. Configure policies for multiple registries
3. Set up monitoring for verification failures
4. Integrate with your CI/CD pipeline
5. Test fail-over scenarios

## References

- [CRI-O Sigstore Tutorial](https://github.com/cri-o/cri-o/blob/main/tutorials/sigstore.md)
- [containers/image Policy Documentation](https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md)
- [CRI-O Configuration](https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md)
- [Cosign Integration](https://docs.sigstore.dev/cosign/overview/)
