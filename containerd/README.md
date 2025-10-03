# Containerd Runtime Signature Verification POC

This POC demonstrates container signature verification at the containerd runtime level using **OCI hooks**.

## Overview

Since containerd doesn't have built-in signature verification (unlike CRI-O), we use **OCI Runtime Hooks** to intercept container creation and verify signatures before allowing containers to start.

### Architecture

```
Kubernetes → Containerd → OCI Runtime (runc) → OCI Hook → Cosign Verify
                                                    ↓
                                            Exit 0 (allow) or Exit 1 (deny)
```

The hook runs before each container starts and checks if the image is properly signed.

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
- Install containerd, docker, cosign, crictl
- Configure containerd
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
- Install OCI hooks (with sudo)
- Run verification tests

### 4. Iterate

```bash
make test && make clean
```

Run this as many times as needed to test changes.

### Step-by-Step (Optional)

```bash
make setup-registry  # Start local registry
make gen-keys        # Generate cosign keys
make sign-image      # Sign test image
make setup-cluster   # Create Kind cluster
make test-hook       # Test hook manually
make test            # Deploy test pods
```

### Check Status

```bash
make status
```

### Cleanup

```bash
make clean      # Remove test pods only
make clean-all  # Remove everything (cluster, registry, keys)
```

## Important Note on Registry Access

The local registry runs as `containerd-registry` on Docker's `kind` network. Inside the Kind cluster:
- ✅ Use `containerd-registry:5000/image:tag` (works inside cluster)
- ❌ Don't use `127.0.0.1:5003/image:tag` (doesn't work inside cluster)

From your host machine:
- ✅ Use `127.0.0.1:5003/image:tag` (for signing with cosign)

The Makefile handles this automatically - signed images at `127.0.0.1:5003` are accessible inside the cluster as `containerd-registry:5000`.

### OCI Hook Script

The hook (`hooks/verify-signature.sh`):
1. Receives container state via stdin (JSON)
2. Extracts the image name from annotations
3. Calls `cosign verify` with the public key
4. Returns exit 0 (allow) or exit 1 (deny)

### Hook Configuration

OCI hooks are configured in `/etc/containerd/cri-base.json`:

```json
{
  "ociVersion": "1.0.2",
  "hooks": {
    "prestart": [
      {
        "path": "/usr/local/bin/verify-signature-hook",
        "args": ["verify-signature-hook"],
        "env": ["COSIGN_PUBKEY=/etc/containerd/keys/cosign.pub"]
      }
    ]
  }
}
```

## Important Notes

### Kind Limitations

Kind uses containerd but with specific CRI configurations. Full OCI hook integration at the runtime level requires:

1. Runtime configuration at the runc level
2. Containerd CRI plugin to pass hook configs
3. Proper hook execution context

**Current POC Status:**
- Hook script implemented and functional
- Can test hook manually
- WARNING: Full automatic runtime enforcement needs additional configuration

### For Production VM

To implement this properly on a production VM:

1. Install containerd and runc
2. Configure `/etc/containerd/config.toml`:
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
    ConfigPath = "/etc/containerd/runc-config.json"
```

3. Create `/etc/containerd/runc-config.json` with hook configuration
4. Restart containerd

## Testing

### Manual Hook Test

```bash
# Inside Kind node
echo '{"annotations": {"io.kubernetes.cri.image-name": "127.0.0.1:5003/alpine:3.20.3"}}' | \
    /usr/local/bin/verify-signature-hook

# Check logs
journalctl -t containerd-verify-hook
```

### Pod Deployment Test

```bash
# Deploy signed pod (should work)
kubectl apply -f manifests/signed-pod.yaml

# Deploy unsigned pod (should fail with full integration)
kubectl apply -f manifests/unsigned-pod.yaml

# Check status
kubectl get pods -l test=signature-verification
```

## Troubleshooting

### Hook not executing

Check if hook is installed:
```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
docker exec $NODE ls -la /usr/local/bin/verify-signature-hook
```

### Hook failing for signed images

Check logs:
```bash
docker exec $NODE journalctl -t containerd-verify-hook -n 50
```

Verify cosign key is present:
```bash
docker exec $NODE cat /etc/containerd/keys/cosign.pub
```

### Images not being verified

Kind's containerd CRI configuration may bypass OCI hooks. For full integration:
1. Use a proper VM with containerd
2. Configure runc directly with hooks
3. Use admission controllers (Kyverno) as an alternative

## Cleanup

```bash
make clean
```

This removes the Kind cluster.

## Comparison with CRI-O

| Feature | Containerd + Hooks | CRI-O |
|---------|-------------------|-------|
| Built-in support | ❌ No | ✅ Yes |
| Configuration | Complex | Simple policy.json |
| Kind support | ✅ Partial | ❌ Difficult |
| Production ready | Custom solution | Native feature |
| Flexibility | High | Policy-based |

## Next Steps

1. Test on a proper VM for full OCI hook integration
2. Add more verification logic (e.g., certificate validation)
3. Implement caching to reduce verification overhead
4. Add monitoring and alerting for verification failures

## References

- [OCI Runtime Spec - Hooks](https://github.com/opencontainers/runtime-spec/blob/main/config.md#posix-platform-hooks)
- [Containerd Configuration](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
