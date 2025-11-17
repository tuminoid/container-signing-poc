# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Repository Overview

This is a container image signing and verification POC that demonstrates
multiple approaches:

1. **Signing**: Using Notation (with custom external signer plugin) or Cosign
2. **Signature Transport**: Using Oras for moving signatures between registries
3. **Admission-time Verification**: Using Kyverno admission controller
4. **Runtime-level Verification**: Using CRI-O (native support) or Containerd
   (OCI hooks)

The POC follows defense-in-depth principle with two verification layers:

- **Layer 1**: Admission controller (Kyverno) - validates before pod creation
- **Layer 2**: Runtime verification (CRI-O/Containerd) - validates before
  container starts

## Common Commands

### E2E Testing (Top Level)

```bash
# Run full Notation flow: sign → oras copy → kyverno verify
make notation

# Run full Cosign flow: sign → kyverno verify
make cosign

# Clean all test artifacts
make clean
```

### Notation Custom Plugin (`notation/`)

```bash
# Build and install the external-signer plugin
make install

# Run full test: build plugin, sign image, verify
make test

# Only sign an image (requires setup)
make sign

# Verify a signed image
make verify

# Clean everything
make clean
```

### Cosign (`cosign/`)

```bash
# Full test: start registry, generate certs, sign, verify
make test

# E2E test including save/load operations
make e2e

# Sign image (requires registry running)
make sign

# Verify signature
make verify

# Save signed image with signatures to disk
make save

# Load saved image back to registry
make load
```

### Kyverno (`kyverno/`)

```bash
# Setup Kind cluster with Kyverno (one-time)
make setup

# Run Notation e2e test
make -f notation.mk

# Run Cosign e2e test
make -f cosign.mk

# Clean up cluster and registry
make clean
```

### Runtime Verification - CRI-O (`crio/`)

```bash
# One-time setup (requires Ubuntu 24.04 VM, needs reboot)
make setup
# <reboot VM>

# Run verification tests
make test

# Check system status
make status

# Clean test artifacts
make clean

# Remove all CRI-O configs
make clean-all
```

### Runtime Verification - Containerd (`containerd/`)

```bash
# One-time setup (requires Ubuntu 24.04 VM, needs reboot)
make setup
# <reboot VM>

# Run verification tests
make test

# Check system status
make status

# Clean test artifacts
make clean

# Remove all containerd hooks and configs
make clean-all
```

## Architecture

### Notation External Signer Plugin

Located in `notation/cmd/notation-external-signer/`, this is a Go-based Notation
plugin that:

- Implements the Notation Plugin Specification
- Acts as a bridge between Notation and external signing scripts/binaries
- Receives payload via stdin, returns signature via stdout
- Supports any signature algorithm (e.g., RSA-PSS with SHA512)
- Uses environment variables for configuration:
  - `EXTERNAL_SIGNER`: Path to signing script/binary
  - `EXTERNAL_PRIVATE_KEY`: Path to private key (for local signing)
  - `EXTERNAL_CERT_CHAIN`: Path to certificate chain PEM

**Key files:**

- `main.go`: Plugin entry point and CLI handling
- `sign.go`: Core signing logic, calls external signer
- `key.go`: Key management and certificate handling
- `metadata.go`: Plugin metadata (capabilities, version)

### Cosign Signing

Cosign signing is handled via shell scripts and OpenSSL:

- Generate payload with `cosign generate`
- Sign payload with OpenSSL (RSA256 with PKCS#1)
- Attach signature with `cosign attach signature`
- Signatures are stored as OCI artifacts in registry
- Can save/load entire image+signatures with `cosign save/load`

### Kyverno Policies

Two ClusterPolicy files in `kyverno/policy/`:

1. `kyverno-policy-notation.yaml`: Verifies Notation signatures
1. `kyverno-policy-cosign.yaml`: Verifies Cosign signatures (with transparency
   logs disabled)

Policies are applied at admission time and prevent unsigned pods from being
created.

### Runtime Verification

**CRI-O Approach** (`crio/`):

- Uses native signature verification via `/etc/containers/policy.json`
- Policy specifies which registries require signatures
- Supports Cosign keyless or key-based verification
- Configuration in `config/policy.json` and `config/registries.d/`
- Requires VM with CRI-O runtime (cannot run on local machine)

**Containerd Approach** (`containerd/`):

- Uses OCI Runtime Hooks (no native support)
- Hook script (`hooks/verify-signature.sh`) intercepts container creation
- Calls `cosign verify` before allowing container to start
- Hook configuration in `hooks/oci-hooks.json`
- Requires VM with containerd runtime (cannot run on local machine)

Both approaches provide runtime-level defense even if admission controller is
bypassed.

## Development Notes

### Testing Registries

Different ports are used to avoid conflicts:

- `127.0.0.1:5000` - Containerd test registry
- `127.0.0.1:5001` - Kyverno Kind registry
- `127.0.0.1:5002` - Notation test registry
- `127.0.0.1:5003` - CRI-O test registry / Cosign test registry

### Certificate Generation

All signing requires certificate chains:

- Root CA certificate
- Leaf certificate (for actual signing)
- Certificate chain (leaf + CA combined)

Notation and Cosign examples auto-generate these with OpenSSL.

### Runtime Verification Requirements

Both CRI-O and Containerd POCs:

- Require Ubuntu 24.04 VM (or similar Linux distro)
- Need sudo/root access for system configuration
- Require reboot after initial setup
- Cannot be tested on local macOS/Windows machines
- Use `crictl` for container management (not `docker`)

### Go Module

The Notation plugin uses:

- Go 1.20+
- `github.com/notaryproject/notation-core-go v1.0.2`
- `github.com/notaryproject/notation-go v1.1.0`

To build: `cd notation && make build`

## Important Constraints

### Signature Algorithm Support

**Notation**: Flexible, supports any algorithm including:

- RSA-PSS with SHA512
- Custom algorithms via external signer

**Cosign/Sigstore**: Limited to:

- RSA256 with PKCS#1 only
- Cannot easily support other algorithms due to Sigstore ecosystem requirements
- All Sigstore services (Fulcio, Rekor) must support the same algorithms

### Transparency Logs

**Cosign**: By default requires transparency logs (Rekor). For private
infrastructure:

- Use `--tlog-upload=false` when signing
- Use `--insecure-ignore-sct` when verifying
- Configure Kyverno policies to disable transparency log checks

**Notation**: Does not require transparency logs by default.

## Testing Strategy

### Unit vs E2E

Each component has its own test cycle:

1. **Notation**: Plugin build → registry setup → sign → verify
1. **Cosign**: Registry setup → cert generation → sign → verify → save/load
1. **Kyverno**: Kind cluster → install Kyverno → apply policies → test pod
   creation
1. **Runtime**: VM setup → install runtime → configure policies → test container
   creation

### Expected Test Behavior

- Pods/containers with **signed images**: Should start successfully
- Pods/containers with **unsigned images**: Should fail with signature
  verification errors
- In Kyverno tests: Look for pods with `success` in name (should exist), pods
  with `fail` in name (should NOT exist)

### Kind Cluster Notes

Due to Kind cluster networking issues, pods may show `ImagePullErr` but this is
expected. The important metric is whether the pod was created (admission passed)
or rejected (admission failed).

## File Structure

```text
.
├── notation/              # Notation external signer plugin (Go)
│   ├── cmd/notation-external-signer/  # Plugin source code
│   └── examples/          # Example signing scripts
├── cosign/                # Cosign signing examples (shell)
├── oras/                  # Oras signature copying (shell)
├── kyverno/               # Kyverno admission controller policies
│   ├── policy/            # ClusterPolicy YAML files
│   └── scripts/           # Kind cluster setup
├── crio/                  # CRI-O runtime verification POC
│   ├── config/            # Policy.json and registry configs
│   ├── scripts/           # VM setup and testing
│   └── manifests/         # Test pod definitions
└── containerd/            # Containerd runtime verification POC
    ├── hooks/             # OCI hook scripts
    ├── scripts/           # VM setup and testing
    └── manifests/         # Test pod definitions
```

## Tips

- Always run `make` without arguments to see available targets
- Check README.md files in each subdirectory for detailed instructions
- Runtime verification POCs require VMs - do not attempt on local machine
- Use `make clean` frequently to reset test state
- When debugging, check container runtime logs: `journalctl -u crio` or
  `journalctl -u containerd`

<!-- cSpell:ignore oras,kyverno,pkcs,sigstore,fulcio,rekor -->
