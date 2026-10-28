# Issue #12: Xbox user authentication HTTP 400

Initial source investigation and review: October 28, 2026. No installed
components, accounts or game data were accessed or changed.

## Evidence and boundaries

- [Issue #12](https://github.com/1JRobertson/bedrock-mac/issues/12) was still open
  with no comments when fetched. It reports successful Microsoft sign-in followed
  by user-auth HTTP 400, `d=` ticket format, no XErr/JSON and reported zero bytes.
- Public `main` fetched as `ed2c5889562d870ed7c2695458119e677a20ac6f`.
  Its Xodus pin matches the reporter:
  `0670e25aeb0e0e9f800f8f2f4968ae3b681842a7`.
- None of the existing public patches changes `api/xbox/auth.rs`,
  `api/xbox/mod.rs`, `models/xbox.rs` or `xodus-cli/src/package.rs`.
  Current upstream Xodus `main`, fetched as
  `514dd56f360a4bdf12f4acde5148bac5ce5f957f`, has identical versions of these
  files and `models/secrets.rs`. Updating that pin alone does not change this path.

The supported download helper calls `package::get_packages`, then
`xodus::api::xbox::run`. It exchanges saved Microsoft STS credentials through SOAP
for a compact token addressed to `user.auth.xboxlive.com`, with policy `MBI_SSL`.
It submits this token unchanged in a JSON POST to
`https://user.auth.xboxlive.com/user/authenticate`:

```json
{
  "RelyingParty": "http://auth.xboxlive.com",
  "TokenType": "JWT",
  "Properties": {
    "AuthMethod": "RPS",
    "SiteName": "user.auth.xboxlive.com",
    "RpsTicket": "<redacted Microsoft compact token>"
  }
}
```

Headers include `Content-Type: application/json` and
`x-xbl-contract-version: 1`. A successful user response would subsequently go to
XSTS for `http://update.xboxlive.com`, then the authenticated package catalog.
The reported failure is before these later requests and before package byte
verification or extraction.

### Proven reporting defect

The pinned `auth.rs` calls `.error_for_status()?` **before reading the body**.
HTTP 400 returns a `reqwest::Error`, discarding the response from the caller.
`xbox/mod.rs:54` then `.expect()`s that result, causing the observed panic.
That line identifies user authentication, not the later XSTS request.

The stock code never attempts to parse an HTTP 400 body. Therefore a helper
diagnostic derived only from this error cannot establish an empty response,
invalid JSON or absent XErr. The reporter's diagnostic modifications were not
provided, so their reported zero-byte measurement cannot yet be validated.

Pinned sources: [HTTP request/error handling](https://github.com/xodus-gaming/xodus/blob/0670e25aeb0e0e9f800f8f2f4968ae3b681842a7/crates/xodus/src/api/xbox/auth.rs),
[panic caller](https://github.com/xodus-gaming/xodus/blob/0670e25aeb0e0e9f800f8f2f4968ae3b681842a7/crates/xodus/src/api/xbox/mod.rs),
[SOAP token conversion](https://github.com/xodus-gaming/xodus/blob/0670e25aeb0e0e9f800f8f2f4968ae3b681842a7/crates/xodus/src/models/secrets.rs).

### What is not established

The reason for HTTP 400 remains unknown. Compatible explanations include an
unacceptable/expired Microsoft ticket or service-side rejection, and a response
from a network intermediary. A status code alone cannot distinguish them.
Microsoft sign-in and SOAP token issuance do not prove Xbox will accept the
issued token. Earlier verified package acquisition proves an earlier attempt
worked, not that the current ticket/service/network state is unchanged.

`d=` alone is not evidence of a prefix defect. `models/secrets.rs` leaves
`urn:passport:compact` bytes unchanged and prefixes `urn:passport:delegationcompact`
with `d=`. The user-auth function does not add another prefix. Microsoft's
[documented website flow](https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/s2s-auth-calls/service-authentication/live-website-authentication?view=gdk-2604)
also uses `d=` and the same user-auth request shape. That OAuth example is not a
specification of Xodus's SOAP flow; it does not establish this ticket's validity.
Do not blindly add/remove prefixes or retry variants with real credentials.

Store market selection is absent from the user-auth request. Wine's WinHTTP
party patch is in a different executable and transport: this failure is in
the native Rust helper's reqwest request, before the game starts. Neither is
supported as the cause by the available evidence.

## Local candidate change

`patches/xbox-auth-errors.patch` retains the same endpoints, request payloads,
tokens and TLS client policy. It returns a typed error instead of panicking on
HTTP user-auth/XSTS failures, and propagates it through package lookup.
Error-body collection has an independent two-second deadline and retains at most
8 KiB temporarily. Diagnostics expose only:

- Fixed stage/kind labels, numeric HTTP status and a fixed media-type category.
- Bytes retained and body state: `complete`, `limited`, `read_error`, `timeout`,
  `unread` or `unmeasured` (a failed 2xx decode with no byte measurement).
- JSON validity only after a complete read, plus an unsigned numeric `XErr`.

`bytes=0` is an observed empty body only with `body=complete`. A limited or failed
read has unknown JSON/XErr, never a fabricated absence. No body text, URL, header
values, account data, tokens or underlying error/source chain is retained in the
error. The helper prints only that concrete type as `BEDROCK_AUTH_DIAGNOSTIC:`
before returning its existing safe `account_package` failure. Arbitrary package
errors continue to be suppressed. Bootstrap and setup use the same new patch;
existing source trees are still verified and never silently rewritten.

This improves failure handling and evidence collection. It does **not** fix or
claim to reproduce Microsoft's rejection of the reporter's real ticket.

## Validation

All Rust checks used toolchain `1.98.0`, the tracked Cargo lockfile, debug builds
and two compiler jobs. Heavy jobs ran sequentially through the workspace's
shared QA resource guard. No unrelated jobs were interrupted.

- `cargo fetch --locked --manifest-path sources/xodus/Cargo.toml`: fetched missing
  public dependencies after the initial offline command refused an uncached
  dependency. No lockfile changes.
- Filtered offline `xodus --lib api::xbox::auth::tests`: **14 passed**, 15 other
  upstream tests filtered out. Only HTTP/1.1 loopback and synthetic tokens;
  includes real POST headers/payloads, exact-cap and partial/stalled-body cases.
  CI runs this same filter separately from the helper example tests, because
  testing a dependent example does not execute library unit tests.
- Regression check: temporarily restored the original `error_for_status` before
  body-reading pipeline, adapting its error type only to run the same assertion.
  The JSON-400 regression failed as expected: `(0, unread, None, None)` instead
  of `(107, complete, true, 2148916227)`. Restored the fix in `finally`, reran the
  initial ten-test filter, and all passed. The reviewed filter now contains
  14 tests. This reproduces discarded diagnostics, not the
  reporter's real Microsoft rejection.
- Offline helper integration command:
  `cargo +1.98.0 test --offline --locked --jobs 2 --no-default-features --manifest-path sources/xodus/Cargo.toml -p xodus-cli --example standalone_helper -- --test-threads=1`:
  **38 passed, 7 ignored**. No opt-in Keychain, account, cached game or CDN tests.
- Python orchestration/source fixtures with `/opt/homebrew/bin/python3.14 -m unittest discover -s tests -p 'test_*.py'`:
  **383 passed**, under the resource guard. Downloads and installed data are
  mocked or isolated fixtures; their progress text does not indicate live use.
- `python3.14 tools/bootstrap-sources.py --project xodus --check`: verified the
  exact pinned source and **162 patched/input files**, including the helper.
- `python3.14 tools/export-source.py --check`: **278 allowlisted files**;
  `LC_ALL=C LC_CTYPE=C LANG=C shasum -a 256 -c SOURCE-SHA256.txt`: all 278 matched
  after inventory refresh, using the supported C locale for macOS Perl.
  Source-export tests passed (14); `git diff --check` passed.

These checks do not establish live TLS/HTTP/2 behavior, real account or service
policy, a release build, or macOS 27 acceptance. No launcher, game or account
session was started. Public dependency downloads were separate from the offline
test runs. An initial source verification detected stale generated helper input;
only the isolated source copy was refreshed, then verification passed.

## Suggested reporter follow-up (draft only)

1. What is the public bedrock-mac commit, and does failure occur on every retry
   or intermittently? Approximately when did the earlier successful download and
   a recent failed attempt occur (UTC)? No account identifiers are needed.
2. Did the zero-byte diagnostic read the response body before
   `error_for_status`, or was zero a fallback after an error? Share only that
   small diagnostic-code change with token values removed, not a full log.
3. If a reviewed candidate is deliberately tested later, share just its single
   `BEDROCK_AUTH_DIAGNOSTIC` line and source revision. In particular, body state,
   media category and numeric XErr can separate empty/HTML/JSON/read failures.
4. Is a VPN, proxy or HTTPS inspection active? If practical, does an ordinary
   alternate network change the outcome? Keep certificate validation enabled;
   do not change trust settings or install a capture certificate.

Do not request raw tickets, authentication headers, response text, signed URLs,
Keychain exports, account identifiers or full unreviewed logs. Testing a new
helper, signing in or replacing installed components needs separate authorization.
