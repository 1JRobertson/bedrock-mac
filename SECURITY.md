# Security and privacy

This repository is an experimental source preview. No public binary release or
supported security-maintenance schedule is established. The latest source and
the known release gates are documented in [docs/RELEASE.md](docs/RELEASE.md).

## Reporting a security issue

Use the repository's GitHub **Security → Report a vulnerability** action if it
is available. If private reporting is unavailable, open an issue asking for a
private contact channel without publishing exploit details, account data, or
secrets. No separate security email or response-time guarantee is configured.
Ordinary setup failures belong in the bug template.

A useful private report gives the affected commit, Mac/OS, component, steps using
synthetic data, expected/actual behavior, and impact. Never send a password,
Keychain export, Microsoft token, content key, complete account response, or
signed download URL. Review logs before sharing excerpts.

## Current boundaries and known gaps

- Microsoft user/device credentials are kept in macOS Keychain. The account
  helper caches one saved item per process and uses direct Keychain writes.
  No plaintext credential fallback is intended.
- The worker forwards only known progress messages and safe error codes to the
  UI. Logs stay on the local Mac; upstream/runtime output still needs review
  before anyone shares it. No automatic bug-report upload is implemented.
- The helper checks the owner's Microsoft license for downloading and launching.
  A copied game directory does not establish ownership.
- Account/catalog/license requests use certificate-verified HTTPS. Game downloads
  use a separate client without account headers or cookies. It permits HTTP for
  `assets1.xboxlive.com` and `assets2.xboxlive.com` on port 80 because the catalog
  supplies those origins. **Some unencrypted package sections are not fully
  authenticated.** A network attacker could tamper with unauthenticated bytes;
  a hostname allowlist and matching length do not prevent that. Complete package
  integrity is required before publishing a binary preview.
- Downloads use private staging directories, validated relative paths, file-size
  checks, and promotion after preparation. These filesystem checks do not close
  the network integrity gap above.
- The Xbox service uses a user-owned mode-0600 Unix socket and process/lock checks.
  This is not a sandbox against other software already running as the same user.
- Current app builds use ad-hoc signatures. Source/resource checksums detect
  differences from recorded bytes; they do not establish a trusted publisher.
  Signing/notarization and clean-Mac checks are separate distribution work.

Do not work around failures by disabling Gatekeeper, skipping hash checks,
trusting all TLS certificates, widening Keychain access, or deleting another
process's socket. Report the failed boundary with redacted evidence instead.

## Source and binary distribution

Only files explicitly listed in `export-source.py` enter source exports.
Ignored runtime directories are not a publication boundary by themselves.
Review the staged file list and checksum inventory before pushing changes.
Never include a game, user data, Microsoft payloads, or raw local logs.

A binary release additionally needs the dependency/notices/corresponding-source
inventory in [THIRD_PARTY.md](THIRD_PARTY.md) and every gate in
[docs/RELEASE.md](docs/RELEASE.md). This document records outstanding risks; it
does not claim that public binary distribution is ready.
