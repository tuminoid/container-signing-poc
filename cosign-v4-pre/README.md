# Cosign "v4-pre": new Sigstore bundle format with BYO PKI
<!-- cSpell:ignore sigstore,oras,kyverno,rekor,fulcio,referrers,pkcs -->

Anticipates **cosign v4**, where the new Sigstore bundle format (v0.3+) is
planned to be the only supported format and the legacy simple-signing /
`cosign attach` paths are removed.

Signs an image with a private PKI (root CA -> intermediate CA -> leaf) using
native `cosign sign`, storing the signature as a v0.3 bundle attached as an OCI
referrer, then verifies it against a trusted root holding **only the root CA**.

Requires **cosign >= 3.1.3** (enforced), **registry:3** for OCI 1.1 referrers,
plus docker, openssl and jq. Test registry is `127.0.0.1:5004`.

```bash
make test     # registry, certs, key import, sign, verify
make clean    # tear down
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

### External signing is not possible on the bundle path

Native bundle signing requires `--key` pointing at a **cosign-encrypted** key.
Plain PEM is rejected, both SEC1 and PKCS#8:

```text
Error: ... reading key: unsupported pem type: EC PRIVATE KEY
```

So the private key must be handed to cosign via `cosign import-key-pair`. There
is no bundle equivalent of the legacy "sign externally, then `cosign attach`"
flow that `../cosign-v2` demonstrates. For a signing service that never
releases key material this is unresolved; KMS URIs cover hosted KMS, but not an
arbitrary in-house signer.

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
Rekor (deliberately absent), and `oras copy -r` relocation.
