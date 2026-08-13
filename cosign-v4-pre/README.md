# Cosign "v4-pre": new Sigstore bundle format with BYO PKI
<!-- cSpell:ignore sigstore,oras,kyverno,rekor,fulcio,referrers,pkcs -->
<!-- cSpell:ignore dsse,intoto,openssl,nokey -->

Anticipates **cosign v4**, where the new Sigstore bundle format (v0.3+) is
planned to be the only supported format and the legacy simple-signing /
`cosign attach` paths are removed.

Signs an image with a private PKI (root CA -> intermediate CA -> leaf), storing
the signature as a v0.3 bundle attached as an OCI referrer, then verifies it
against a trusted root holding **only the root CA**. Two signing flows are
demonstrated:

- `make test` signs natively with `cosign sign` and a cosign-imported key.
- `make v4-external-offline` signs with `openssl` alone, never running cosign at
  signing time, and publishes the bundle with `oras attach`. This mirrors an
  asynchronous, in-house signing server.

Requires **cosign >= 3.1.3** (enforced), **registry:3** for OCI 1.1 referrers,
plus docker, openssl, jq and oras. Test registry is `127.0.0.1:5004`.

```bash
make test          # native cosign sign, then verify
make v4-external-offline  # cosign-free openssl signing + oras publish, then verify
make clean         # tear down
```

No deprecated flags are used: `--new-bundle-format` is omitted (bundles are the
default in 3.1.3+), `--trusted-root` replaces `--ca-roots`, and
`--insecure-ignore-tlog` replaces `--private-infrastructure`.

## Findings

### sigstore/cosign#3976 is fixed on the bundle codepath

[Issue #3976](https://github.com/sigstore/cosign/issues/3976) reported that the
intermediate and the root CA had to come from the *same* source to verify. Here
the bundle carries **leaf + intermediate only** while the trusted root carries
**the root CA only**, and verification succeeds - so `make test` passing *is*
the demonstration that the issue is fixed.

The fix is [sigstore-go#581](https://github.com/sigstore/sigstore-go/pull/581),
which appends bundle-supplied intermediates to the trusted CA's intermediates
during path building. It shipped in sigstore-go v1.2.2, first released in
cosign 3.1.3:

| cosign | sigstore-go | works |
| --- | --- | --- |
| 3.1.0 / 3.1.1 | v1.2.0 | no |
| 3.1.2 | v1.2.1 | no |
| **3.1.3** | **v1.2.2** | **yes** |

On 3.1.1 this cannot even be signed: `cosign sign` verifies the bundle it just
produced and fails with `failed to verify leaf certificate`.

The legacy path is still affected, see `../cosign-v3` target
`repro-3976-legacy`.

### `--allow-certificate-chain` is mandatory and its absence is silent

Consuming an X.509 chain from bundle verification material requires
`--allow-certificate-chain`. Without it cosign does not report skipping the
bundle; it falls back to the legacy path and fails with a misleading
`no signatures found`. In `cmd/cosign/cli/verify/verify.go`, `GetBundles`
returning nothing resets `co.NewBundleFormat` with no warning. The
`verify-expect-fail` target asserts this, so it fails if diagnostics improve.

### External signing is possible, but not through `cosign attach`

An earlier version of this document claimed external signing was impossible on
the bundle path. That was wrong. What is true is narrower: `cosign sign --key`
will not take a raw PEM private key file, rejecting both SEC1 and PKCS#8:

```text
Error: ... reading key: unsupported pem type: EC PRIVATE KEY
```

There are two ways to keep the private key away from cosign:

1. **Synchronous, via a plugin.** `cosign sign --key "name://ref"` runs a
   `sigstore-kms-name` binary from `PATH` as a signing oracle
   ([sigstore#1901](https://github.com/sigstore/sigstore/pull/1901),
   [cosign#4073](https://github.com/sigstore/cosign/pull/4073)). Cosign still
   orchestrates and blocks on the plugin, so this suits an online signer, not an
   asynchronous one. Not implemented here.
1. **Asynchronous, without cosign at all.** Build the bundle yourself and
   publish it as an OCI referrer. Implemented here as
   `make v4-external-offline`, see below.

`pkcs11:` and cloud KMS URIs (`awskms://` and friends) are further options where
the key never reaches cosign.

### Signing without cosign, asynchronously

`make v4-external-offline` runs `sign-offline.sh`, which never invokes cosign. It
models an in-house process where a signing server holds HSM keys, signs when it
pleases and does not run cosign:

1. **Client, before signing.** The payload is derived from the image digest
   alone: an in-toto statement whose only subject is the image digest, with
   predicate type `https://sigstore.dev/cosign/sign/v1`. The signed bytes are
   the DSSE pre-authentication encoding
   `DSSEv1 <len(type)> <type> <len(payload)> <payload>`.
1. **Signing server, asynchronous.** `openssl dgst -sha384 -sign` over the PAE.
   The leaf is P-384, which cosign classifies as SHA-384, so SHA-384 is used to
   avoid cosign's compatibility fallback. In production this is a separate host
   with the key in an HSM, and may answer hours later.
1. **Client, after signing.** Assemble the v0.3 bundle (leaf + intermediate, no
   root, no transparency log) and publish it as an OCI referrer.

Because the signer produces both the payload and the signature, there is no
canonicalisation dependency on cosign; verification uses the payload bytes
carried in the bundle.

Publishing uses `oras attach`, which handles both the referrers API and, on
registries that lack it, the fallback tag `sha256-<image-digest>` that cosign
needs for discovery. `registry:3` 3.1.1 returns HTTP 404 on the referrers API
in this setup, so the fallback tag is what actually gets used; publishing by
digest alone fails verification with the misleading `no signatures found`. The
same result is achievable with plain registry API calls, so nothing beyond an
OCI registry is fundamentally required, but `oras attach` is the sane choice.

Mapping to a typical existing process, only the last step changes: build image
(unchanged), upload payload to signing server (now a DSSE PAE), server signs
with openssl and HSM (unchanged), download signature (unchanged), and `cosign
attach` becomes bundle assembly plus an `oras attach`.

Negative control, manual. Verification reads from the registry, so editing local
files after publishing proves nothing; the tampered bundle must be the one
published, to a clean registry. Using a distinct repository keeps it a
one-registry exercise:

```bash
make clean setup-nokey
IMG=127.0.0.1:5004/alpine@sha256:33735bd63cf84d7e388d9f6d297d348c523c044410f553bd878c6d7829612735
./sign-offline.sh "$IMG"                      # produces examples/bundle.json
# flip one base64 character of the signature
jq '.dsseEnvelope.signatures[0].sig |= "A" + .[1:]' examples/bundle.json > examples/bad.json
oras attach --plain-http \
  --artifact-type application/vnd.dev.sigstore.bundle.v0.3+json \
  127.0.0.1:5004/alpine-bad@sha256:...  \
  examples/bad.json:application/vnd.dev.sigstore.bundle.v0.3+json
# verify against the tampered repo must fail with a signature error
```

The point is only that a corrupted signature is rejected; wire it to whichever
repository and digest are convenient.

### Bundles cannot be transported with `cosign save` / `load`

`cosign save` writes only the image: the saved `index.json` holds a
`dev.cosignproject.cosign/image` entry and no `dev.cosignproject.cosign/sigs`
entry as it did for legacy signatures, so loading elsewhere yields an unsigned
image. `cosign copy` is deprecated and copies the *image* onto the bundle's
fallback tag; its deprecation notice recommends `oras copy -r`, the likely
relocation path for v4 (see `../oras`, not wired up here).

Trap worth knowing: loading or copying into the **same repository** appears to
verify fine, because bundles are found via referrers keyed by image digest, so
the *original* bundle is still discovered. Always relocate to a different
repository when testing transport.

## Not covered

Kyverno admission control (bundle + BYO-PKI support there is unverified),
Rekor (deliberately absent), the synchronous plugin signer (Path A, planned),
and `oras copy -r` relocation between registries (distinct from the `oras
attach` publish shown here).
