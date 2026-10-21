# Release readiness

**Not ready for a seamless public binary release.** This is a source preview;
local release preparation is underway. Nothing has been posted or published by
the release team. Public download: **pending**.

Artifact snapshot: October 7, 2026; source/report updates through October 21. Source baseline `73b120b0ed6e5e4bec8e0319b73fba6765f9135a`
plus pre-existing staged work and current uncommitted release fixes. That commit
alone does not identify a built artifact. The current local test artifact is
**0.3.0 RC4 (build 6)**, built October 7 (Vancouver) from a captured source snapshot.
Its inspected minimum is **macOS 15.0**. It is ad-hoc signed and not notarized.

- DMG: `Bedrock-for-Mac-0.3.0-rc4-local.dmg` — 154,596,576 bytes.
- SHA-256: `2843d513f425c0eb17669c3fa73356e91244b77349863a07cbe8384583201fb5`.
- Package audit: 95 native files, 1,961 verified resources, 15 contained symlinks;
  strict signature and mounted-DMG checks passed; no external non-system loads/RPATHs.
- The helper is exactly `3e717611…`, which passed full verified acquisition
  outside the app. That result does not qualify native RC4 first-run.
- All 908 selected notices match. The bundled launcher's source and `__text`
  match the actual final SwiftUI quit/window fixture. Frozen updater success,
  failure and cancellation pass with synthetic data; real update is untested.

RC4 combines the source-built v4 runtime, verified acquisition helper and
quit/window lifecycle fix. Earlier RC3 functioning, normal-return and quit-alert
observations remain historical. No RC4 native first-run, gameplay, save/reopen,
soak or M1 pass is claimed. Public download is **pending**.

The [October 21 source audit](AUDIT.md) records subsequent fixes and focused
checks. It does not update the RC4 artifact or close its native release gates.

## Current gates

**Pass** means the named evidence passed within its stated scope. **Fail** means
a known requirement is unmet. **Untested** means no qualifying candidate result.
**External blocker** needs a user, account, certificate, or second-machine action.

| Gate | Status | Evidence / remaining work |
| --- | --- | --- |
| Current source regression snapshot | Pass — source scope | PR #6 CI at `d048f09`: all five jobs passed, including 336 Python tests on macOS, native launcher, helper and picker contracts; 193-file source inventory verified; not packaged-candidate acquisition/gameplay proof |
| Historical source/runtime checks | Pass — historical only | Dated fixture and development records in [TESTING.md](TESTING.md) and [STABILITY.md](STABILITY.md) |
| Public runtime reconstruction | Pass — build/graphics scope | v4 pinned source replay: ten build steps and two exact-bridge GPU validation steps passed; gameplay remains separate |
| Actual RC3 packaged GPU probes | Pass — GPU probe scope | Disposable-prefix presentation/readback/texture/discard probes passed; all 1,959 resource hashes and signature remained intact; no account/game in these probes |
| RC4 app/DMG and OS audit | Pass — artifact/smoke scope | macOS 15.0; 1,961 resources/15 links, strict signature, exact helper and launcher fixture code verified; no live app/game in independent audit |
| Secure download source/fixtures | Pass — narrow transport scope | HTTPS policy/negative fixtures and a two-byte routing probe passed; these do not prove real package availability |
| RC2 / RC3 older acquisition helper | **Fail — historical route retained in RC3** | RC2 recorded four initial HTTPS GET 404 responses; RC3 still uses the older helper |
| Exact RC4 helper acquisition | Pass — isolated helper scope | `3e717611…` passed catalog/ownership-bound verified acquisition/preparation before packaging; exact bytes now in RC4; not native-app or clean-M1 acceptance |
| Native RC4 onboarding/gameplay | Untested — qualifying receipt absent | A prior working note reports same-Mac first-run/retry and window checks, but no artifact-bound acceptance receipt is included here; first-run, live update, gameplay and M1 qualification remain pending |
| RC4 packaged notice-copy coverage | Pass — exact-copy scope | 908 notices match selected inputs; final source/build provenance limits remain separate |
| Corresponding-source / build provenance | Untested — final distribution mapping | RC4 uses source-built native dependencies and collected helper/Python notices; final binary corresponding-source mapping remains a gate; [THIRD_PARTY.md](../THIRD_PARTY.md) |
| Local Gatekeeper assessment | Fail — expected for ad-hoc build | Packaging reports rejection; no clean signed/downloaded-app result |
| Developer ID / notarization | External blocker | User has no Apple Developer membership; no Developer ID identity or notarization |
| Clean M1 install and sign-in | Untested; external test needed | Maintainer reports it working on an M1 MacBook Air, 16 GB; exact OS/revision/scenarios and clean-state acceptance receipt still needed |
| RC3 functioning / normal return | Pass — bounded same-Mac report | User-confirmed functioning with copied owned payload; launcher returned to Play and owned processes exited. Direct exit code not captured; no save/reopen or timed-soak pass |
| RC4 frozen update fixtures | Pass — synthetic scope | Success/failure/cancel cases and 12 interrupted-update guards passed using fake backend/journal/save data; real update/recovery pending |
| RC4 quit/window fixture | Pass — exact-code synthetic scope | Final native SwiftUI close/reopen, repeated Quit, Keep Open and automatic dismissal passed; bundled code matches; real game lifecycle pending |
| Candidate save/reopen and restore | Untested | Use disposable worlds and separate backups |
| Candidate multiplayer | Untested | Verify actual join, disconnect and rejoin; Xbox, PS5, featured servers and Realm entry are separate cases |
| Candidate extended session | Untested | Record duration, memory trend, failures and normal save/exit |
| Cancel/retry/update source fixtures | Pass — source scope | 36 onboarding fixtures plus 26 standalone and 9 packaging checks; synthetic worker-death recovery and retained newer-world bytes; native fixture renders/controller checks |
| RC3 Cancel at initial Keychain wait | Pass — bounded live scope | Native Cancel stopped the helper; no socket remained, no prefix was created and no game started; imported payload key hashes unchanged |
| Retry / download cancellation / live update | Untested | The Keychain-wait cancellation does not prove retry, authentication, download cancellation or game-update rollback |
| Historical claim audit | Pass — historical scope | 14 claims and 95 arithmetic checks; no cumulative FPS claim |
| Candidate demo | Untested | Reviewed historical screenshot available; new candidate footage still required |
| Publication | Not authorized | Download URL and release tag remain pending |

## Reported issues

- [Skin import crash (#4)](https://github.com/1JRobertson/bedrock-mac/issues/4):
  **Dressing Room → Choose New Skin** was reported to crash at source revision
  `99fc9aa`. Current source adds modern/UWP open/save pickers and the game's
  `StorageFile.GetFileFromPathAsync` dependency, with verified runtime staging,
  prefix registration, packaging and independent ABI contracts. October 19
  native testing on an M4 Pro passed dialog opening/cancellation, invalid-image
  handling and PNG import/rendering, including a Unicode filename. The reported
  picker crash no longer reproduces on that baseline; #4 remains open for
  reporter verification. October 20 tracing found that 26.52 saves custom PNGs
  then clears them during startup, consistent with Mojang's MCPE-241720.
  Mojang announces a fix in 26.60.24 Preview; a newer game has not been validated
  here. World import/export regression remains pending. See the
  [dated diagnosis and limits](TESTING.md#october-20-skin-persistence-diagnosis).
- [Adventure-preview scenery report (#5)](https://github.com/1JRobertson/bedrock-mac/issues/5):
  the report references `4ed3a6f` and scenery code absent from this source tree.
  It needs the correct repository or reproducible source before a fix can be
  verified here.

An unsigned local candidate can support testing. It is not a passed Gatekeeper
or notarized distribution result. Native ARM research is separate and does not
block qualification of a safe Windows-runtime preview.

## RC2 live attempt, October 7

On the development Mac, native app opening passed with fresh standard app data
and the existing user's Keychain. The corrected run reached sign-in, catalog
lookup and package selection, then all four recorded initial package GETs
returned HTTPS **404**. This was not a HEAD-only check. A successful two-byte
routing probe does not establish that the endpoint serves actual game paths.
That failure remains evidence about the older helper, not the replacement
acquisition result below; certificate/connectivity failure was not established.

An earlier test overrode `HOME` and lost default Keychain lookup (`-25307`);
that scaffold was invalid for authentication and was corrected before the
package failure above. Failure cleanup passed in its recorded scope: no helper,
game process, Xbox socket, staging directory or game payload remained at handoff.
This does not prove cancellation or update rollback. Original credentials/worlds
were preserved. Game launch, save/reload, relaunch, multiplayer and soak were
**not run in that RC2 attempt**. Hold the M1 acquisition handoff until the
replacement helper is packaged and the new candidate passes.

## Replacement acquisition and RC3 return, October 7

Helper `3e7176112949f9b4d7ee9b3228242c09894dcba24385ed21f0c98ab49ddcbe1a`
completed fresh private acquisition with exit 0. The recorded sequence bound the
current catalog content and signed version, checked real ownership before bulk
download, verified the production signature plus 2,975 tree / 502,386 data /
589 metadata pages, then extracted and prepared the game through the verified
local reader. The promoted output contains 12,179 files; static game config
reports **1.26.5203.0**. Staging and quarantine were empty; original paths were
unchanged. This is an isolated helper result, not RC4 native first-run or new-helper gameplay,
clean-M1 installation, or a packaged update test.

Separately, the user confirmed RC3 functioning with the copied owned payload.
The launcher returned to Play; its helper receipt and locks were cleared, with
no Xbox socket left. The game exit code was not captured directly: normal return
is supported by the checked worker path, Ready state and absence of failure
markers. Save/reopen is unverified; no session duration is promoted to a soak
or performance result.

## Historical evidence retained

- October 20 maintainer report: estimated **10+ total hours with Xbox and
  PlayStation friends** across multiple sessions. This adds cumulative
  user-reported experience to the two individually monitored sessions below;
  [gameplay evidence](STABILITY.md#repeated-cross-platform-play).
- Maintainer report: working on an **M1 MacBook Air with 16 GB RAM**. Exact OS,
  source/app revision and scenarios are unrecorded; clean-machine and RC4
  acceptance remain separate checks.
- September 30: M4 Pro, 24 GB, macOS 15.3.1, WineGDK 11.8, DXMT v0.80,
  Minecraft 1.26.52. User-confirmed Xbox and PS5 friend-world sessions;
  [stability notes](STABILITY.md) retain durations, memory observations and limits.
- October 2: the existing-install native app launched Minecraft on the development
  Mac. After the user chose **Always Allow**, a repeat launch of that unchanged
  helper did not prompt for Keychain access. This does not test changed-helper
  upgrades, a fresh owner account, or a downloaded app.
- October 5–7: optional performance experiments and fixture results are retained
  in [performance evidence](PERFORMANCE.md), [testing](TESTING.md), and original
  JSON records. Their installation into a source runtime does not put them into
  a separately packaged candidate.

The previous October 2 release document reported macOS 26 for a local assembled
bundle. The development host and historical game runs use macOS 15.3.1.
The RC4 binary audit above supersedes that old floor for this artifact. It does not establish clean-M1 gameplay support.

## Final acceptance record

Before a download is advertised, confirm the selected artifact and its hash,
then record its exact game version, dependency inventory and security result.
Attach source/fixture, local
app, clean-M1, multiplayer, save/restore, update, and soak results separately.
Include failed cases and remaining limitations in [release notes](RELEASE_NOTES.md).
Use [TESTING.md](TESTING.md) for checks and [PUBLISHING.md](PUBLISHING.md) for
reviewed source inventories. Source checksums and ad-hoc signing do not replace
account/game-download verification, gameplay testing, or notarization.
