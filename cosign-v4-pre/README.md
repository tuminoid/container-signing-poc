# Cosign "v4-pre": new Sigstore bundle format with BYO PKI
<!-- cSpell:ignore sigstore,oras,kyverno,rekor,fulcio,referrers,pkcs -->
<!-- cSpell:ignore dsse,intoto,openssl,nokey -->

Anticipates **cosign v4**, where the new Sigstore bundle format (v0.3+) is
planned to be the only supported format and the legacy simple-signing /
`cosign attach` paths are removed.

Signs an image with a private PKI (root CA -> intermediate CA -> leaf), storing
the signature as a v0.3 bundle attached as an OCI referrer, then verifies it
against a trusted root holding **only the root CA**. The flows:

- `make test` signs natively with `cosign sign` and a cosign-imported key.
- `make v4-external-plugin` signs through an external `sigstore-kms-*` plugin,
  so the private key never reaches cosign, while cosign still orchestrates.
- `make v4-external-offline` signs with `openssl` alone, never running cosign
  at signing time, and publishes the bundle with `oras attach`. This mirrors
  an asynchronous, in-house signing server.
- `make v4-tsa` signs the shape Kyverno can admit: leaf-only bundle, signed
  timestamp from a timestamp authority, CA chain in the trusted root.
- `make v4-external-offline-tsa` builds that shape without cosign.
- `make v4-relocate` runs `v4-tsa`, then moves the image and its bundle
  through an OCI layout tarball with `oras cp -r` and verifies at the
  destination.

Requires **cosign >= 3.1.3** (enforced), an OCI 1.1 registry (**registry:3**
or zot), plus docker, openssl, jq and oras. Ports are listed in
[../AGENTS.md](../AGENTS.md).

```bash
make test                 # native cosign sign, then verify
make v4-external-plugin   # external signer via sigstore-kms plugin, then verify
make v4-external-offline  # cosign-free openssl signing + oras publish, then verify
make v4-tsa               # leaf-only bundle with signed timestamp, then verify
make v4-external-offline-tsa  # same shape, cosign-free, then verify
make v4-relocate          # v4-tsa, relocate via OCI layout tarball, verify there
make v4-offline-relocate  # v4-external-offline-tsa, relocate, verify there
make v4-rsa               # v4-offline-relocate with an RSA 4096 leaf
make v4-referrers         # v4-offline-relocate on registry:3 and on zot
make v4-save-load         # cosign save and load of a bundle-signed image
make v4-dev-signatures    # development plus production bundle, three exports
make v4-rotation          # two CA generations in one trusted root
make v4-multiarch         # v4-rsa, then an index signed two ways
make v4-shapes            # three bundle shapes for the Kyverno tripwires
make v4-tls               # cosign-free signing and verification on a TLS registry
make v4-leaf-expiry       # timestamped bundle outlives its leaf, untimestamped not
make v4-san-required      # registered-ID-only leaf must fail verification
make clean                # tear down
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
bundle; cosign 3.x falls back to the legacy path and fails with a misleading
`no signatures found`. In `cmd/cosign/cli/verify/verify.go`, `GetBundles`
returning nothing resets `co.NewBundleFormat` with no warning. Cosign `main`,
which has no legacy path, fails with an equally misleading `no valid bundles
exist in registry`. The `verify-expect-fail` target asserts either, so it
fails if diagnostics improve.

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
   asynchronous one. Implemented here as `make v4-external-plugin`; the plugin is
   `sigstore-kms-poc`, a small openssl wrapper that reads the key from
   `KEY_PEM`. Architecturally this is the same model as the Notation
   external-signer plugin in `../notation`.
1. **Asynchronous, without cosign at all.** Build the bundle yourself and
   publish it as an OCI referrer. Implemented here as
   `make v4-external-offline`, see below.

`pkcs11:` and cloud KMS URIs (`awskms://` and friends) are further options where
the key never reaches cosign.

The plugin must declare an algorithm that matches the key and digest. The leaf
is ECDSA P-384, which cosign classifies as SHA-384, so `sigstore-kms-poc`
declares `ecdsa-sha2-384-nistp384` and signs with a SHA-384 digest. A mismatch
(for example signing with SHA-256) still verifies, but only through cosign's
compatibility verifier, which prints `Failed to verify signature with default
verifier, trying compatibility verifier` at signing time.

### Signing without cosign, asynchronously

`make v4-external-offline` runs `sign-offline.sh`, which never invokes cosign. It
models an in-house process where a signing server holds HSM keys, signs when it
pleases and does not run cosign:

1. **Client, before signing.** The payload is derived from the image digest
   alone: an in-toto statement whose only subject is the image digest, with
   predicate type `https://sigstore.dev/cosign/sign/v1`. The signed bytes are
   the DSSE pre-authentication encoding
   `DSSEv1 <len(type)> <type> <len(payload)> <payload>`.
1. **Signing server, asynchronous.** `openssl dgst -sign` over the PAE, with
   the hash cosign's verifier expects for the leaf key: SHA-384 for P-384,
   SHA-256 with PKCS#1 v1.5 padding for RSA. In production this is a separate
   host with the key in an HSM, and may answer hours later.
1. **Client, after signing.** Assemble the v0.3 bundle (no root, no
   transparency log) and publish it as an OCI referrer.

Because the signer produces both the payload and the signature, there is no
canonicalisation dependency on cosign; verification uses the payload bytes
carried in the bundle.

Publishing uses `oras attach`, which handles both the referrers API and, on
registries that lack it, the fallback tag `sha256-<image-digest>` that cosign
needs for discovery. `registry:3` returns HTTP 404 on the referrers API, so
the fallback tag is what gets used there; zot serves the API and gets no tag.
`make v4-referrers` signs, verifies and relocates on both and asserts which
mechanism each used; `../kyverno/bundle-zot.mk` admits from zot. The same
result is achievable with plain registry API calls, so nothing beyond an OCI
registry is fundamentally required, but `oras attach` is the sane choice.

Mapping to a typical existing process, only the last step changes: build image
(unchanged), upload payload to signing server (now a DSSE PAE), server signs
with openssl and HSM (unchanged), download signature (unchanged), and `cosign
attach` becomes bundle assembly plus an `oras attach`.

### Entry point for other repositories

`sign-offline.sh` takes an arbitrary image, registry and key material, and
runs from any directory:

```bash
KEY=/path/leaf.key LEAF=/path/leaf.crt WORK_DIR=/path/work \
TSA_URL=http://tsa.example.com/api/v1/timestamp \
  /path/to/cosign-v4-pre/sign-offline.sh registry.example.com/repo@sha256:<digest>
```

| Input | Meaning |
| -- | -- |
| argument | image by digest, `<registry>/<repo>@sha256:<64 hex>`; a tag is refused |
| `KEY` | signing key, PEM: RSA, or ECDSA P-256, P-384 or P-521. The signing server's role |
| `LEAF` | leaf certificate, PEM, with an email or URI SAN |
| `WORK_DIR` | created if missing; receives the statement, PAE, signature and `bundle.json` |
| `INTERMEDIATE` | optional intermediate certificate, PEM: set, the bundle carries leaf plus intermediate |
| `TSA_URL` | optional RFC 3161 timestamp authority: set, the bundle carries a signed timestamp |
| `PLAIN_HTTP` | `true` (default) for a plain http registry, `false` for TLS. A registry CA outside the system roots goes in `SSL_CERT_FILE`, which oras reads (`make v4-tls`) |

The Kyverno-admissible shape is `TSA_URL` set and `INTERMEDIATE` unset, with
the intermediate and the TSA chain in the verifier's trusted root. Requires
openssl, jq, curl and oras; registry credentials are oras's. `../crio`
`sign-image-bundle-only` calls it from another directory with its own PKI.

Negative control, manual. Verification reads from the registry, so editing local
files after publishing proves nothing; the tampered bundle must be the one
published, to a clean registry. Using a distinct repository keeps it a
one-registry exercise:

```bash
make clean setup-nokey
IMG=127.0.0.1:5004/alpine@sha256:33735bd63cf84d7e388d9f6d297d348c523c044410f553bd878c6d7829612735
KEY=examples/leaf.key LEAF=examples/leaf.crt WORK_DIR=examples \
  ./sign-offline.sh "$IMG"                    # produces examples/bundle.json
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

### Bundles relocate with `oras cp -r`; `cosign save` / `load` carry them too

`cosign save` lists only the image in the saved `index.json`, as
`dev.cosignproject.cosign/image`, with no `dev.cosignproject.cosign/sigs`
entry as for legacy signatures, but writes the bundle manifest and blob into
`blobs/`, and `cosign load` into another repository restores the referrer,
which verifies there. The layout is cosign's own: `oras discover` finds no
referrer in it. `make v4-save-load` asserts all three. `cosign copy` is
deprecated and copies the *image* onto the bundle's fallback tag; its
deprecation notice recommends `oras cp -r`.

`make v4-relocate` uses `oras cp -r`: to an OCI layout, tar, untar,
`oras cp -r` into another repository, verify there. The image digest is
unchanged and the bundle referrer comes along, in a standard layout, so this
is the air-gapped transport the Kyverno flows use. For an index, `oras cp -r`
brings the referrers of the platform manifests along as well
(`make v4-multiarch`, `../kyverno/bundle-multiarch.mk`).

Trap worth knowing: loading or copying into the **same repository** appears to
verify fine, because bundles are found via referrers keyed by image digest, so
the *original* bundle is still discovered. Always relocate to a different
repository when testing transport.

### The production algorithm: RSA 4096, PKCS#1 v1.5, SHA-256

`make v4-rsa` runs the cosign-free admissible flow with an RSA 4096 leaf
carrying a URI SAN: openssl signs with SHA-256 and PKCS#1 v1.5 padding, the
client adds the timestamp, oras publishes and relocates, cosign verifies at
the destination. The target reads the bundle back and asserts the leaf is RSA
4096 with the URI SAN and the signature recovers as PKCS#1 v1.5 over a SHA-256
digest. Kyverno admits it (`../kyverno` `cosign-v4-pre.mk SIGN_TARGET=v4-rsa`)
and so does the containerd verifier (`../containerd` test 7).

### Development signatures

An image signed in development and again for production carries two bundles.
`make v4-dev-signatures` signs one with a development PKI and a production
PKI, behind one TSA, and exports it three ways, each checked at the
destination with the production trusted root, which lacks the development CA:

| Option | Result |
| -- | -- |
| Delete the development bundle, then export | `oras manifest delete` of the referrer also removes it from the fallback tag index, which keeps the production bundle; one bundle exported, production root verifies, development root fails |
| Copy the image alone to a clean promotion repository, sign production there, export | one bundle exported, production root verifies, development root fails |
| Export both | both bundles exported; each root verifies its own, and the production root verifies the image. Kyverno admits it (`../kyverno/bundle-dev.mk`) |

An image carrying only the development bundle fails the production root, in
cosign and in Kyverno, with `failed to verify leaf certificate`. Deletion
needs a registry that allows it (`REGISTRY_STORAGE_DELETE_ENABLED` for
`registry:3`).

### Trust anchor rotation

One trusted root can hold two CA generations, each with a validity window.
`make v4-rotation` signs one image under each generation and asserts: with
both in the root, gen1 open until tomorrow and gen2 open since yesterday, both
verify; with gen1 dropped, or its window closed before the signing time, gen1
signatures fail with `failed to verify leaf certificate`. Classical keys only;
ML-DSA is covered by `container-signing-pqc-poc`.

### Multi-arch

`make v4-multiarch` copies a linux/amd64 plus linux/arm64 index twice and
signs `multi/index-only` on the index digest alone and `multi/platform-only`
on each platform manifest alone. Bundles are referrers of one digest, so
cosign verifies exactly the digest it is given: the index-only bundle does
not cover its platform manifests, and the platform bundles do not cover the
index. A consumer that resolves the tag verifies the index; one that pulls a
platform digest verifies that. Signing both covers both. Kyverno and the
containerd verifier behave alike, see `../kyverno/bundle-multiarch.mk` and
`../containerd` tests 8 to 11.

### Admission with Kyverno needs a leaf-only bundle and a timestamp

Kyverno 1.20 `ImageValidatingPolicy` rejects the bundles from `test`,
`v4-external-plugin` and `v4-external-offline`. `make v4-shapes` signs one
image per shape without cosign, all of which `cosign verify` accepts, and
`../kyverno/bundle-shapes.mk` asserts the Kyverno result and its error, so a
Kyverno release that changes either fails there:

| Bundle | Kyverno result | Cause |
| -- | -- | -- |
| Leaf plus intermediate, signed timestamp | `no signatures found` | Kyverno never passes `AllowCertificateChain`, so sigstore-go drops the bundle |
| Leaf only, no timestamp | `threshold not met for verified signed timestamps` | With the tlog ignored Kyverno requires a signed timestamp |
| Leaf only, signed timestamp | admitted | `v4-tsa`, `v4-external-offline-tsa`, `v4-rsa` |

`v4-tsa` therefore moves the intermediate from the bundle into the trusted
root, and adds an RFC 3161 timestamp authority to both the signing config and
the trusted root. The policy uses a `keyless` attestor with an inline
`trustedRoot`, see
[../kyverno/policy/kyverno-policy-bundle.yaml](../kyverno/policy/kyverno-policy-bundle.yaml)
and `make -f cosign-v4-pre.mk` there. The TSA here is the timestamp-server
memory signer; a real deployment chains the TSA to its own PKI.

The timestamp has a second effect: verification checks the leaf against the
signing time instead of the current time, so signatures outlive the leaf
certificate. `make v4-leaf-expiry` signs two images with a leaf valid for
40 seconds, one with a timestamp and one without, and waits for the leaf to
expire: the timestamped bundle still verifies, the other fails with `failed
to verify leaf certificate`. `../kyverno/bundle-expiry.mk` admits the
timestamped image with the leaf expired.

`make v4-external-offline-tsa` builds the same shape without cosign: the
client drops the intermediate and adds an RFC 3161 timestamp over the
signature returned by the signing server. Kyverno admits it as well.

### The signing certificate needs an email or URI SAN

Certificate verification in cosign 3.x requires an identity, read only from
email, URI or other-name SANs; `gencrt.sh` sets a URI SAN. A certificate whose
only SAN is, say, a registered ID fails on the bundle path with `failed to
summarize certificate: no Subject Alternative Name found`, in `cosign verify`
and in Kyverno alike, and on the legacy `cosign verify` path with `got subjects
[]`. Only `--key` with the bare public key, or Kyverno's legacy `certChain`
attestor, accept it. Check the certificate profile before migrating;
`make v4-san-required` asserts the failure with a registered-ID-only leaf.

## Not covered

Rekor (deliberately absent), CRL or OCSP revocation (no Sigstore support), and
CRI-O / Podman runtime verification, whose library cannot read bundles
(container-libs#388); `../crio` test 5 asserts that a bundle-only image is
refused there.
