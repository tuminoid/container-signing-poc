<!-- cSpell:ignore oras,kyverno,airgap,rsassa,pkcs,sigstore,fulcio -->

# Cosign v3 POC (BYO-PKI with v3 Binary)

> **Cosign v4:** this flow uses `cosign generate` and `cosign attach signature`,
> both removed on cosign `main` (`attach` is replaced by bundle-only `attach
> bundle`). Run it with cosign v3.1.x or older via `COSIGN_BIN`. Verifying
> legacy signatures is removed on `main` too (`--ca-roots` and
> `--new-bundle-format` are gone), see `make tripwire-cosign-main`. For the v4
> path see [../cosign-v4-pre](../cosign-v4-pre/README.md).

This POC demonstrates using the Cosign v3 binary with BYO-PKI certificates
for external signing. For BYO-PKI use cases (OpenSSL-generated keys), the
workflow remains the same as v2, but using the v3 binary ensures compatibility
with v3's internal signature handling and bundle format.

**Key differences from cosign-v2:**

- **v2**: Uses cosign v2.x binary with `cosign attach signature`
- **v3**: Uses cosign v3.x binary with `cosign attach signature`

**Important Notes:**

1. **BYO-PKI Constraint**: `cosign sign --key` rejects a plain PEM key. An
   OpenSSL key must first go through `cosign import-key-pair`, see
   [../cosign-v4-pre](../cosign-v4-pre/README.md); `sign-native` here uses a
   cosign-generated key instead. The default flow keeps the key out of cosign
   with the external signer approach (`cosign generate`, OpenSSL sign,
   `cosign attach signature`).

1. **Bundle Format**: Cosign v3.0+ defaults to `--new-bundle-format=true`,
   which requires `--trusted-root` instead of `--ca-roots`. For BYO-PKI with
   CA-based verification, you MUST set `--new-bundle-format=false` when
   verifying:

   ```bash
   cosign verify --new-bundle-format=false --ca-roots=ca.crt ...
   ```

   Without this flag, you'll get: "CA roots/intermediates must be provided
   using --trusted-root when using --new-bundle-format"

**Trust model:** Both v2 and v3 use the same CA-based certificate verification.

## Preparation

NOTE: all this is done by `make test`, this is just explaining what it does.

1. Verify basic tools exist

   We need three tools installed and available in PATH:

   - docker
   - cosign v3.0.2+
   - openssl

1. Run local registry where we can upload images and signatures

   Commonly, `docker run -d --restart=always -p 127.0.0.1:5007:5000 registry:2`
   does the trick.

1. Push public alpine image to a local registry for testing

   ```sh
   docker pull alpine:3.20.3
   docker tag alpine:3.20.3 127.0.0.1:5007/alpine:3.20.3
   docker push 127.0.0.1:5007/alpine:3.20.3
   ```

1. Generate certificates for signing. We generate CA, sub-CA and leaf.

   ```sh
   ./gencrt.sh
   ```

## Signing (v3 Binary with BYO-PKI)

The workflow is the same as v2 for BYO-PKI compatibility:

1. Generate payload

   ```sh
   cosign generate 127.0.0.1:5007/alpine:3.20.3 > examples/payload.json
   ```

1. Sign with OpenSSL (external signer)

   ```sh
   openssl dgst -sha256 -sign examples/leaf.key \
       -out examples/payload.sig examples/payload.json
   base64 examples/payload.sig > examples/payloadbase64.sig
   ```

1. Attach signature using v3 binary

   ```sh
   cosign attach signature \
       --payload examples/payload.json \
       --signature examples/payloadbase64.sig \
       --certificate examples/leaf.crt \
       --certificate-chain examples/certificate_chain.pem \
       127.0.0.1:5007/alpine:3.20.3
   ```

   The v3 binary handles this with v3's internal format.

## Verifying

We verify with cosign using CA roots, as v2, with the legacy format selected:

```sh
cosign verify \
    --new-bundle-format=false \
    --ca-roots=examples/ca.crt \
    --certificate-identity-regexp '.*' \
    --certificate-oidc-issuer-regexp '.*' \
    --private-infrastructure \
    --insecure-ignore-sct \
    "127.0.0.1:5007/alpine:3.20.3"
```

## Backward Compatibility

The `make verify-v2-sigs` target tests that v3 cosign can verify v2 attached
signatures:

```sh
make verify-v2-sigs
```

This sets up v2 registry, signs with v2 workflow, then verifies with v3 cosign
binary.

## Exporting and importing

Cosign can be used to export and import images with signatures, without need for
external tools like [Oras](../oras/README.md).

- `make pack` calls `cosign save ...` and tarballs the OCI layer dump.
- `make unpack` unpacks the tarball, and `cosign load ...` it back into registry.

## Local Image Verification

`make e2e-local` saves the signed image to a local OCI layout and verifies it
with `--local-image`, without `--new-bundle-format`, so cosign detects the
legacy format itself. Before cosign 3.0.5
([sigstore/cosign#4621](https://github.com/sigstore/cosign/issues/4621))
`--local-image` could not be combined with `--new-bundle-format`, the v3
default.

## Comparison with v2

| Aspect | v2 (cosign-v2) | v3 (cosign-v3) |
|--------|---------------|---------------|
| Binary Version | cosign v2.x | cosign v3.0.2+ |
| BYO-PKI Signing | External signer + `cosign attach signature` | External signer + `cosign attach signature` |
| Workflow | `cosign generate`, OpenSSL, `attach signature` | `cosign generate`, OpenSSL, `attach signature` |
| Trust Model | CA-based certificate verification | CA-based certificate verification |
| Verification | `cosign verify --ca-roots` | `cosign verify --new-bundle-format=false --ca-roots` |
| Bundle Format | Legacy format (implicit) | Must disable new format: `--new-bundle-format=false` |
| Compatibility | v3 can verify v2 signatures (with `--new-bundle-format=false`) | Backward compatible |

**Critical Notes:**

1. **`cosign sign --key`:** This native v3 signing command takes a cosign
   key, so an OpenSSL BYO-PKI key must go through `cosign import-key-pair`
   first, handing it to cosign. Keeping the key out of cosign takes the
   external signer workflow here, or a `sigstore-kms-*` plugin or a
   cosign-free bundle in [../cosign-v4-pre](../cosign-v4-pre/README.md).

1. **`--new-bundle-format=false`:** Required for v3 verification when using
   `--ca-roots`. Without this flag, cosign v3 will error with "CA
   roots/intermediates must be provided using --trusted-root when using
   --new-bundle-format".
