# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Repository Overview

This is a container image signing and verification POC that demonstrates
multiple approaches:

1. **Signing**: Using Notation (with custom external signer plugin), Cosign v2
   (external signer), Cosign v3 (native signing), or Cosign v4-pre (new
   Sigstore bundle format only)
1. **Signature Transport**: Using Oras for moving signatures between registries
1. **Admission-time Verification**: Using Kyverno admission controller
1. **Runtime-level Verification**: Using CRI-O (native support) or Containerd
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

# Run Cosign v2 flow: sign → kyverno verify
make cosign-v2

# Run Cosign v3 flow: sign → kyverno verify
make cosign-v3

# Run both cosign flows
make cosign

# Run Cosign v4-pre flow: standalone bundle sign + verify, no kyverno
make cosign-v4-pre

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

### Cosign v2 (`cosign-v2/`)

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

### Cosign v3 (`cosign-v3/`)

```bash
# Full test: start registry, generate certs, sign, verify
make test

# Sign image with v3 native signing (requires registry running)
make sign

# Verify v3 signature
make verify

# Test v3 verifying v2 signatures (backward compatibility)
make verify-v2-sigs

# Save/load operations (same as v2)
make save
make load

# Reproduce sigstore/cosign#3976 on the legacy attach path (still broken)
make repro-3976-legacy
```

### Cosign v4-pre (`cosign-v4-pre/`)

Requires **cosign >= 3.1.3** (enforced) and **registry:3** for OCI 1.1
referrers. Uses no deprecated flags, since v4 makes bundles the only format.

```bash
# Full test: registry, certs, key import, sign, verify (+ negative control)
make test

# External signer via a sigstore-kms plugin (key never given to cosign)
make v4-external-plugin

# Cosign-free asynchronous signing, published with oras attach
make v4-external-offline

# Individual steps, idempotent after setup
make setup
make sign
make verify

# Tear down registry and generated material
make clean
```

`make test` passing is itself the demonstration that sigstore/cosign#3976 is
fixed on the bundle codepath: the bundle carries leaf + intermediate only,
while the trusted root carries only the root CA.

### Kyverno (`kyverno/`)

```bash
# Setup Kind cluster with Kyverno (one-time)
make setup

# Run Notation e2e test
make -f notation.mk

# Run Cosign v2 e2e test
make -f cosign-v2.mk

# Run Cosign v3 e2e test
make -f cosign-v3.mk

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

**Cosign v2**: Signing is handled via shell scripts and OpenSSL:

- Generate payload with `cosign generate`
- Sign payload with OpenSSL (RSA256 with PKCS#1)
- Attach signature with `cosign attach signature`
- Signatures are stored as OCI artifacts in registry
- Can save/load entire image+signatures with `cosign save/load`

**Cosign v3**: Uses native cosign signing:

- Sign directly with `cosign sign --key`
- Uses new v3 Sigstore bundle format
- Same CA-based verification as v2
- Can verify v2 attached signatures (backward compatible)
- Can save/load entire image+signatures with `cosign save/load`

**Cosign v4-pre**: Native signing into a v0.3 Sigstore bundle:

- Sign with `cosign sign --key --certificate --certificate-chain`, no
  deprecated flags
- Bundle is stored as an OCI referrer, requiring registry:3
- Chain in the bundle holds leaf + intermediate, root comes from
  `--trusted-root`
- Verification requires `--allow-certificate-chain`, and its absence fails
  silently with `no signatures found`
- Key must be imported with `cosign import-key-pair` for native signing, but
  external signing is still possible via a `sigstore-kms-*` plugin or by
  building the bundle without cosign (`make v4-external-offline`)
- `cosign save`/`load` cannot transport bundles

### Kyverno Policies

Two ClusterPolicy files in `kyverno/policy/`:

1. `kyverno-policy-notation.yaml`: Verifies Notation signatures
1. `kyverno-policy-cosign.yaml`: Verifies Cosign signatures (with transparency
   logs disabled) - works for both v2 and v3 as both use CA-based verification

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

- Uses **Transfer Service image verifier plugin** (containerd 2.1+)
- This is the official/recommended approach since PR #8515 (Apr 2025)
- Verifier binary in `/opt/containerd/image-verifier/bin/`
- Config: `io.containerd.image-verifier.v1.bindir` plugin
- Calls `cosign verify` with BYO-PKI certificates
- **Limitation**: Only verifies on registry pulls (cached images bypass)
- Requires VM with containerd 2.1+ runtime

Both approaches provide runtime-level defense even if admission controller is
bypassed.

## Development Notes

### Testing Registries

Different ports are used to avoid conflicts:

- `127.0.0.1:5000` - Containerd test registry
- `127.0.0.1:5001` - Kyverno Kind registry
- `127.0.0.1:5002` - Notation test registry
- `127.0.0.1:5003` - CRI-O test registry / Cosign test registry
- `127.0.0.1:5004` - Cosign v4-pre test registry (registry:3)

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

**Cosign/Sigstore**: Limited to the algorithms in sigstore's
[algorithm registry](https://github.com/sigstore/sigstore/blob/main/pkg/signature/algorithm_registry.go):

- RSA PKCS#1 v1.5 (2048/3072/4096) with SHA-256, and ECDSA P-256, P-384, P-521
- RSA-PSS and SHA-512-with-RSA are excluded
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
├── cosign-v2/             # Cosign v2 signing (external signer + attach)
├── cosign-v3/             # Cosign v3 native signing (new bundle format)
├── cosign-v4-pre/         # Cosign v4-pre (v0.3 bundles only, registry:3)
├── oras/                  # Oras signature copying (shell)
├── kyverno/               # Kyverno admission controller policies
│   ├── policy/            # ClusterPolicy YAML files
│   └── scripts/           # Kind cluster setup
├── crio/                  # CRI-O runtime verification POC
│   ├── config/            # Policy.json and registry configs
│   ├── scripts/           # VM setup and testing
│   └── manifests/         # Test pod definitions
└── containerd/            # Containerd runtime verification POC
    ├── scripts/           # VM setup, verifier plugin, testing
    ├── config/            # (empty - config generated at runtime)
    └── manifests/         # Test pod definitions
```

## Tips

- Always run `make` without arguments to see available targets
- Check README.md files in each subdirectory for detailed instructions
- Runtime verification POCs require VMs - do not attempt on local machine
- Use `make clean` frequently to reset test state
- When debugging, check container runtime logs: `journalctl -u crio` or
  `journalctl -u containerd`

<!-- cSpell:ignore oras,kyverno,pkcs,sigstore,fulcio,rekor,referrers -->
