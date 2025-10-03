# Runtime Signature Verification POCs - Standalone Edition

## Overview

Two **completely standalone** POCs for container signature verification at runtime level:

1. **containerd** - OCI hooks-based (works with Kind, no VM needed)
2. **crio** - Native verification (requires VM with CRI-O)

Each POC is fully self-contained with its own:
- Key generation
- Image signing
- Local registry
- Test infrastructure
- Cleanup scripts

## Containerd POC (Test Immediately!)

```bash
cd containerd
make all
```

That's it! Everything is automatic:
- ✅ Starts local registry
- ✅ Generates keys
- ✅ Signs test image
- ✅ Creates Kind cluster
- ✅ Installs OCI hook
- ✅ Runs tests

**Cleanup & Rerun:**
```bash
make clean-all  # Remove everything
make all        # Rebuild from scratch
```

## CRI-O POC (Requires VM)

```bash
cd crio

# Setup (no sudo)
make setup-registry gen-keys sign-image

# Install (requires sudo)
sudo make install-policy

# Test
make test
```

**Cleanup & Rerun:**
```bash
sudo make clean-all  # Remove everything
make setup-registry gen-keys sign-image
sudo make install-policy
```

## Features

### ✅ Standalone
No dependencies between directories. Each POC works independently.

### ✅ Idempotent
Safe to run multiple times. Checks if components exist.

### ✅ Proper Cleanup
- `make clean` - Remove test pods
- `make clean-all` - Remove EVERYTHING

### ✅ Status Checking
```bash
make status  # Check what's installed/running
```

### ✅ Easy Iteration
Perfect for development:
1. Modify hook/policy
2. `make clean-all`
3. `make all`
4. Test changes

## Directory Structure

```
containerd/
├── Makefile                    # All-in-one automation
├── README.md                   # Detailed docs
├── hooks/
│   └── verify-signature.sh     # OCI hook script
├── scripts/
│   └── test-hook.sh            # Test script
├── manifests/                  # Test pods
├── kind/                       # Kind config
└── examples/                   # Generated keys (gitignored)

crio/
├── Makefile                    # All-in-one automation
├── README.md                   # Detailed docs
├── config/
│   ├── policy.json             # CRI-O policy
│   └── registries.d/           # Registry config
├── scripts/
│   └── test-verification.sh    # Test script
├── manifests/                  # Test pods
└── examples/                   # Generated keys (gitignored)
```

## What Gets Created

### Containerd
- Local registry: `containerd-registry` (127.0.0.1:5003)
- Kind cluster: `signature-verification`
- Keys: `containerd/examples/cosign.{key,pub}`
- Signed image: `127.0.0.1:5003/alpine:3.20.3`

### CRI-O
- Local registry: `crio-registry` (127.0.0.1:5003)
- Keys: `crio/examples/cosign.{key,pub}`
- Signed image: `127.0.0.1:5003/alpine:3.20.3`
- Policy: `/etc/containers/policy.json`
- Public key: `/etc/containers/keys/cosign.pub`

## Makefile Targets

### Common to Both

```bash
make all           # Complete setup
make status        # Check configuration
make test          # Run tests
make clean         # Remove test pods
make clean-all     # Remove everything
```

### Containerd Specific

```bash
make setup-registry  # Start registry
make gen-keys        # Generate keys
make sign-image      # Sign test image
make setup-cluster   # Create Kind cluster
make test-hook       # Test hook manually
```

### CRI-O Specific

```bash
make setup-registry    # Start registry
make gen-keys          # Generate keys
make sign-image        # Sign test image
make install-policy    # Install policy (sudo)
make test              # Test verification
```

## Testing Workflow

### Development Cycle

```bash
# 1. Make changes to hook/policy
vim containerd/hooks/verify-signature.sh
# or
vim crio/config/policy.json

# 2. Clean up
make clean-all

# 3. Rebuild and test
make all

# 4. Check results
make status
```

### Continuous Testing

Both POCs are designed for rapid iteration:
- Full rebuild in < 2 minutes (containerd)
- Full rebuild in < 1 minute (crio, if VM ready)

## Requirements

### Containerd POC
- Docker
- Kind
- kubectl
- cosign
- jq

### CRI-O POC
- VM with CRI-O installed
- Docker (for local registry)
- cosign
- crictl

## Documentation

- **containerd/README.md** - Full containerd POC documentation
- **crio/README.md** - Full CRI-O POC documentation
- **GETTING_STARTED.md** - Quick start guide
- **RUNTIME_VERIFICATION_PLAN.md** - Detailed implementation plan

## No Cross-Dependencies!

Each POC:
- ❌ Does NOT depend on ../cosign
- ❌ Does NOT depend on each other
- ✅ Generates its own keys
- ✅ Signs its own images
- ✅ Runs its own registry
- ✅ Cleans up after itself

## Quick Start Summary

**Want to test NOW?**
```bash
cd containerd && make all
```

**Have a VM with CRI-O?**
```bash
cd crio
make setup-registry gen-keys sign-image
sudo make install-policy
make test
```

**Made changes and want to retest?**
```bash
make clean-all && make all
```

That's it! Everything is self-contained and ready to use.
