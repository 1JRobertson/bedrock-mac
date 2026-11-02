# Dependency review — November 2, 2026

Enabling GitHub dependency alerts produced nine findings after its initial scan:
one high, three moderate and five low. This review covers the supported
`aarch64-apple-darwin` standalone helper and the developer packaging environment.
It does not qualify other targets or the historical legacy helper.

## Changes and scope

| Dependency | Decision |
| --- | --- |
| Rustls 0.23.43 | Update the active helper TLS stack to 0.23.46. This is a compatible patch update; Cargo also reconciles the existing tempfile/getrandom dependency edge. |
| Setuptools 84.0.0 | Pin 84.1.0 in the packaging requirements. The reported wheel path issue is Windows-specific, but the patch update is suitable for our developer toolchain too. |
| Rustls 0.21.12 / WebPKI 0.101.7 | Retain the upstream transitive lock entries. The supported helper's Xal/OAuth2 clients use native TLS; this older Rustls backend is not selected. |
| WebPKI 0.103.15 | Already newer than the 0.103.13 fix used by the active Rustls stack. |
| GLib 0.18.5 | Retain the cross-platform upstream lock entry. It is absent from the supported Mac target graph; Wry's Linux GTK backend is outside this product's scope. |

The Rustls update addresses the upstream [handshake-level advisory](https://github.com/rustls/rustls/security/advisories/GHSA-2mjx-qc3c-rqvc)
and the [October advisories](https://github.com/rustls/rustls/security): session
debug output, certificate decompression and key-exchange caching. The other
reports concern [WebPKI CRL parsing](https://github.com/rustls/webpki/security/advisories/GHSA-82j2-j2ch-gfr8),
[wildcard](https://github.com/advisories/GHSA-xgp8-3hg3-c2mh) and
[URI name constraints](https://github.com/advisories/GHSA-965h-392x-2mh5),
[GLib's string iterator](https://rustsec.org/advisories/RUSTSEC-2024-0429.html)
and [Setuptools wheel handling](https://github.com/pypa/setuptools/security/advisories/GHSA-xmj3-9gf7-h52w).

## Why the old TLS entries are scoped out

The locked Xal source is `6aa2420f8f0d5e6f7460ff13f399037583a942f4`.
Its authenticator creates `reqwest::Client::new()`; OAuth2 4.4.2 also uses the
default client builder. Neither the pinned Xal/OAuth2 call sites nor this
project's helper selects `use_rustls_tls` or a preconfigured Rustls client.

For Reqwest 0.11.27, the resolved Mac features include `default-tls` and exclude
`http3`. Its `TlsBackend::default()` therefore selects the native-TLS backend,
even though OAuth2 also enables compilation of the Rustls backend. The older
Rustls/WebPKI entries remain in the lockfile, but they are not the TLS backend
used by these client constructors. The separate Reqwest 0.13 path does use the
Rustls stack updated above.

Recheck this assessment when changing the Xal, OAuth2 or Reqwest pins, TLS
features, client constructors or supported platforms. GLib needs its own fix
before treating a Linux build as supported. This is a target and call-site
assessment, not a claim that every locked crate is patched.

## Validation boundaries

Use the final PR and release receipts for exact source identities and command
results. With Rust 1.98.0, the updated locked source passed 19 offline Xbox tests,
38 standalone-helper tests with default features disabled, and two executable-
preparation tests. Seven existing opt-in helper tests stayed ignored. All 162
pinned patched Xodus source inputs verified. A fresh packaging environment passed
dependency checks and imported Setuptools 84.1.0 and PyInstaller 6.22.3.
Mac target and feature graphs support the scope above. Final Python/source-export
checks are recorded in the release receipt.

No account sign-in, game launch, installed-helper replacement or app release is
part of this update. An existing installed helper keeps its old dependencies
until rebuilt and deliberately replaced. Clean-Mac and packaged-app acceptance
remain separate gates.
