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
   (Transfer Service verifier)

The POC follows defense-in-depth principle with two verification layers:

- **Layer 1**: Admission controller (Kyverno) - validates before pod creation
- **Layer 2**: Runtime verification (CRI-O/Containerd) - validates before
  container starts

## Common Commands

### E2E Testing (Top Level)

```bash
# Run full Notation flow: sign → oras copy → kyverno verify
make notation

# Run Cosign v2 flow: sign → cosign save/load → kyverno verify
make cosign-v2

# Run Cosign v3 flow: sign → cosign save/load → kyverno verify
make cosign-v3

# Run both cosign flows
make cosign

# Run Cosign v4-pre: bundle flows standalone, then every bundle
# Kyverno flow (sign → oras relocation → kyverno verify)
make cosign-v4-pre

# Tripwire: cosign main at a pinned commit fails the legacy attach flow
make tripwire-cosign-main

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

Requires **cosign >= 3.1.3** (enforced) and an OCI 1.1 registry, registry:3 or
zot. Uses no deprecated flags, since v4 makes bundles the only format.

```bash
# Full test: registry, certs, key import, sign, verify (+ negative control)
make test

# External signer via a sigstore-kms plugin (key never given to cosign)
make v4-external-plugin

# Cosign-free asynchronous signing, published with oras attach
make v4-external-offline

# Kyverno-admissible shape: leaf-only bundle, signed timestamp from a TSA
make v4-tsa

# v4-tsa, then relocate image + bundle via OCI layout tarball, verify there
make v4-relocate

# Further flows, each asserting one finding, see cosign-v4-pre/README.md
make v4-rsa v4-referrers v4-save-load v4-dev-signatures v4-rotation \
    v4-multiarch v4-shapes v4-tls v4-leaf-expiry

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
# Setup Kind cluster, registry:3, zot and pinned Kyverno (rerunnable,
# registries start empty)
make setup

# Run Notation e2e test
make -f notation.mk

# Run Cosign v2 e2e test
make -f cosign-v2.mk

# Run Cosign v3 e2e test
make -f cosign-v3.mk

# Run Sigstore bundle e2e test (cosign-v4-pre v4-tsa; SIGN_TARGET=v4-rsa,
# DIGEST=false), and the further bundle flows
make -f cosign-v4-pre.mk
make -f bundle-dev.mk   # also bundle-zot.mk bundle-shapes.mk bundle-multiarch.mk
                        # bundle-expiry.mk

# ClusterPolicy refused, ImageValidatingPolicy API versions
make api-versions

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
- Bundle is stored as an OCI referrer, requiring an OCI 1.1 registry: the
  fallback tag on registry:3, the referrers API on zot
- Chain in the bundle holds leaf + intermediate, root comes from
  `--trusted-root`
- Verification requires `--allow-certificate-chain`, and its absence fails
  silently with `no signatures found`
- Key must be imported with `cosign import-key-pair` for native signing, but
  external signing is still possible via a `sigstore-kms-*` plugin or by
  building the bundle without cosign (`make v4-external-offline`)
- `sign-offline.sh` is the cosign-free entry point for other repositories,
  configured by environment variables, see `cosign-v4-pre/README.md`
- `cosign save`/`load` carry bundles in a layout only `cosign load` reads;
  `oras cp -r` moves them through a standard layout (`make v4-relocate`)
- Kyverno admits a bundle only when it carries the leaf alone (intermediate in
  the trusted root) and a signed timestamp (`make v4-tsa`)

### Kyverno Policies

`ImageValidatingPolicy` (`policies.kyverno.io/v1`) files in `kyverno/policy/`,
since Kyverno 1.20 no longer runs `ClusterPolicy`:

1. `kyverno-policy-notation.yaml`: Notation signatures, root CA
1. `kyverno-policy-cosign.yaml`: legacy Cosign signatures (v2 and v3), root CA,
   transparency log disabled
1. `kyverno-policy-bundle.yaml`: Sigstore bundles, inline trusted root

`__TRUST__` in each is replaced with the flow's CA or trusted root by
`kyverno/common.mk`. Each flow signs elsewhere, relocates into the Kind
registry, and asserts unsigned is denied and signed is admitted and running.

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
- Calls `cosign verify` with BYO-PKI certificates: a root CA PEM for legacy
  signatures, or a trusted root `.json` for bundles
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
- `127.0.0.1:5003` - CRI-O test registry / Cosign v2 test registry
- `127.0.0.1:5004` - Cosign v4-pre test registry (registry:3)
- `127.0.0.1:5005` - Oras standalone destination registry
- `127.0.0.1:5006` - Cosign v4-pre timestamp authority
- `127.0.0.1:5007` - Cosign v3 test registry
- `127.0.0.1:5008` - Cosign v4-pre zot registry (OCI referrers API)
- `127.0.0.1:5009` - Kyverno Kind zot registry (`kind-zot`)
- `127.0.0.1:5012` - Cosign v4-pre TLS registry (registry:3, https only)

### Certificate Generation

All signing requires certificate chains:

- Root CA certificate
- Leaf certificate (for actual signing)
- Certificate chain (leaf + CA combined)

Notation and Cosign examples auto-generate these with OpenSSL.

### Runtime Verification Requirements

Both CRI-O and Containerd POCs:

- Run in disposable QEMU VMs via `make -C vm crio` / `make -C vm containerd`
  (`vm/`, host needs qemu, cloud-image-utils and /dev/kvm, no root)
- Require Ubuntu 24.04 VM (or similar Linux distro)
- Need sudo/root access for system configuration
- Require reboot after initial setup
- Use `crictl` for container management (not `docker`)

### Go Module

Versions are in `notation/go.mod`. To build: `cd notation && make build`

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
- Kyverno flows assert this themselves and exit non-zero otherwise

### Kind Cluster Notes

Workloads and Kyverno reach the registry by its kind network IP, mapped to
plain http in containerd (`kyverno/scripts/kind-cluster.sh`). Kyverno's bundle
referrer fetch ignores `--allowInsecureRegistry` and only falls back to http
for private IPs, so a container name does not work for bundles.

All kubectl and helm calls use `--context kind-kyverno`; never rely on the
current context, other Kind clusters may share the machine.

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
│   ├── policy/            # ImageValidatingPolicy YAML files
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
- Runtime verification POCs require VMs: run them through `make -C vm`,
  never on the host
- Use `make clean` frequently to reset test state
- When debugging, check container runtime logs: `journalctl -u crio` or
  `journalctl -u containerd`

<!-- cSpell:ignore oras,kyverno,pkcs,sigstore,fulcio,rekor,referrers -->
