# Runtime Signature Verification - Getting Started

Quick guide for testing the POCs.

## Containerd POC (Kind-based) - Can Test Locally

### Prerequisites
- Docker running
- Kind installed ✅
- kubectl installed
- Cosign signatures ready

### Quick Start

```bash
cd containerd

# Complete setup and test in one command
make all

# Or step by step:
make setup      # Create Kind cluster with hooks
make sign       # Sign test images (uses ../cosign)
make test-hook  # Test hook manually
make test       # Deploy test pods

# Check status
make status

# Cleanup
make clean      # Remove test pods only
make clean-all  # Remove entire cluster
```

### What it does
1. Creates Kind cluster named `signature-verification`
2. Installs OCI hook script into cluster node
3. Copies cosign public key into node
4. Tests hook with signed/unsigned images
5. Demonstrates signature verification concept

### Expected Results
- Hook script verifies signatures correctly
- Signed images pass verification
- Unsigned images fail verification
- Pods may still start (Kind limitation - hook demo only)

---

## CRI-O POC (VM-based) - Requires VM

### Prerequisites
- VM with CRI-O installed
- Root/sudo access on VM
- crictl installed

### Quick Start

```bash
# On VM with CRI-O
cd crio

# Complete setup (requires sudo)
sudo make all

# Or step by step:
sudo make install-policy  # Install policy.json
sudo make copy-keys       # Copy cosign public key
sudo make restart-crio    # Restart CRI-O

# Test (no sudo needed)
make test

# With Kubernetes
make test-pods

# Check status
make status

# Cleanup
make clean      # Remove test pods
sudo make clean-all  # Remove policy files
```

### What it does
1. Installs signature verification policy
2. Configures CRI-O to verify signatures
3. Tests with signed/unsigned images
4. Real runtime enforcement (not just demo)

### Expected Results
- ✅ Signed images pull successfully
- ❌ Unsigned images are rejected by CRI-O
- Runtime enforces signature verification

---

## Comparison

| Feature | Containerd (Kind) | CRI-O (VM) |
|---------|------------------|------------|
| Can test locally | ✅ Yes | ❌ Requires VM |
| Real enforcement | ⚠️ Demo only | ✅ Yes |
| Setup complexity | Easy | Medium |
| Time to test | 5 minutes | 15 minutes + VM setup |

---

## Common Operations

### Rerun after changes

**Containerd:**
```bash
make clean-all  # Remove everything
make all        # Rebuild and test
```

**CRI-O:**
```bash
sudo make clean-all      # Remove config
sudo make all            # Reinstall
sudo systemctl restart crio
make test
```

### Check logs

**Containerd:**
```bash
# Get node name
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# Check hook logs
docker exec $NODE journalctl -t containerd-verify-hook -n 20
```

**CRI-O:**
```bash
# Check CRI-O logs
sudo journalctl -u crio -n 50

# Follow logs
sudo journalctl -u crio -f
```

### Troubleshooting

**Containerd - Hook not working:**
```bash
make status  # Check installation
docker exec <node> ls -la /usr/local/bin/verify-signature-hook
docker exec <node> cat /etc/containerd/keys/cosign.pub
```

**CRI-O - Images not verified:**
```bash
make status  # Check configuration
cat /etc/containers/policy.json
sudo journalctl -u crio | grep -i signature
```

---

## Integration with Existing Setup

Both POCs reuse the existing cosign infrastructure:

```bash
# Sign images first (from root directory)
cd cosign
make test  # This signs alpine:3.20.3

# Then test runtime verification
cd ../containerd && make all  # or
cd ../crio && sudo make all
```

---

## Next Steps

1. **Test containerd POC first** (no VM needed)
   - `cd containerd && make all`
   - See hook verification in action

2. **Setup VM for CRI-O POC**
   - Create VM with CRI-O
   - `cd crio && sudo make all`
   - See real runtime enforcement

3. **Compare behaviors**
   - Both verify signatures
   - CRI-O enforces at runtime
   - Containerd demonstrates with hooks

---

## Files Overview

### Containerd POC
```
containerd/
├── Makefile                    ← Main automation
├── README.md                   ← Detailed docs
├── hooks/
│   └── verify-signature.sh    ← OCI hook script
├── scripts/
│   ├── setup-kind.sh          ← Cluster setup
│   └── test-hook.sh           ← Test hook
├── manifests/
│   ├── signed-pod.yaml        ← Test pod (signed)
│   └── unsigned-pod.yaml      ← Test pod (unsigned)
└── kind/
    └── kind-config.yaml       ← Kind cluster config
```

### CRI-O POC
```
crio/
├── Makefile                    ← Main automation
├── README.md                   ← Detailed docs
├── config/
│   ├── policy.json            ← Signature policy
│   └── registries.d/          ← Registry configs
├── scripts/
│   ├── setup-vm.sh            ← VM setup
│   └── test-verification.sh   ← Test script
└── manifests/
    ├── signed-pod.yaml        ← Test pod (signed)
    └── unsigned-pod.yaml      ← Test pod (unsigned)
```

---

## Documentation

- **Detailed Plans:** See RUNTIME_VERIFICATION_PLAN.md
- **Quick Summary:** See RUNTIME_VERIFICATION_SUMMARY.md
- **Containerd Details:** See containerd/README.md
- **CRI-O Details:** See crio/README.md
