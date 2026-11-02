# Release readiness

Updated November 2, 2026. **The public project is a source preview.** There is
no public notarized app/installer. Source PRs do not publish or qualify binaries.
The intended player experience is open the app, complete required setup/sign-in,
and reach vanilla Minecraft.

The [source preview plan](SOURCE_PREVIEW.md) and [roadmap](ROADMAP.md) cover
source publication and the next acceptance steps.

## Current gates

| Area | Recorded evidence | Still required |
| --- | --- | --- |
| Source checks | The source release and each PR record their final tested revision, Python/Rust results, source hashes and export checks | Tests appropriate to each new change; disclose unavailable hosted CI |
| Runtime construction | Pinned-source v4 replay and exact-bridge graphics probes passed historically | Qualify the runtime selected for each new app |
| Ownership/download | Exact RC4 helper completed verified owner-account acquisition outside the app | New artifact's native first-run, retry and download cancellation |
| App/DMG | Local RC4 resource, notice-copy, signature and complete minimum-OS audit passed | Rebuild/audit any changed app; verify its exact artifact |
| Saves and updates | Historical development save/reopen and synthetic update/recovery checks | Candidate save/reopen/backup restore and actual game upgrade/recovery |
| Multiplayer/stability | User reports and two monitored friend sessions in [gameplay history](history/GAMEPLAY.md#repeated-cross-platform-play); October 31 installed WinHTTP fix followed by a successful friend-world retry ([record](history/PARTY-WINHTTP-2026-10-25.md#october-31-installed-fix-and-friend-world-acceptance)) | Candidate join/disconnect/rejoin, party creation/invites, active Realm entry and extended session |
| Clean-machine/M1 | Maintainer reports it working on an M1 Air, 16 GB; exact OS/revision/scenarios unrecorded | Fresh-machine setup and artifact-specific acceptance receipt |
| Distribution | Source-built dependency receipts and collected notices exist | Final binary corresponding-source/build mapping; Developer ID/notarization and downloaded-app checks |

[PR #10](https://github.com/1JRobertson/bedrock-mac/pull/10) passed its hosted
Python, native-launcher, account-helper and file-picker checks before merging.
Each later PR must record checks on its own final commit and disclose unavailable
jobs; an earlier pass cannot qualify changed source. Native test gaps remain
visible even when a source change is ready for review.

The current [source download](SOURCE_PREVIEW.md) is **0.3.0 source preview 4**,
published November 2. The latest hosted run, on October 28, passed both Python
jobs, account-helper and file-pickers; native-launcher was cancelled. It was not
a complete passing run. Hosted checks are manual; local checks remain the
default merge evidence. See [the run](https://github.com/1JRobertson/bedrock-mac/actions/runs/40701249996)
and [validation policy](TESTING.md#local-validation-record).

## Recorded local artifact

The latest recorded local candidate is **0.3.0 RC4, build 6**, built October 7,
2026, ad-hoc signed and not notarized. Its complete binary audit found a
**macOS 15.0** floor; later builds need their own audit.

DMG: `Bedrock-for-Mac-0.3.0-rc4-local.dmg`

SHA-256: `2843d513f425c0eb17669c3fa73356e91244b77349863a07cbe8384583201fb5`

The [artifact record](history/RELEASE-2026-10-07.md) retains sizes, exact helper
identity, resource/notice counts, RC2 acquisition failure, RC3 bounded return
and all prior limits. No new source cleanup rebuilds those bytes. Native RC4
first-run, gameplay/save-reopen, clean-M1, live update/recovery, multiplayer and
soak acceptance remain open; an unbound working note does not close them.

## Reported issues

- [Custom-skin picker crash (#4)](https://github.com/1JRobertson/bedrock-mac/issues/4):
  current local native checks no longer reproduce the dialog crash. Reporter
  verification and world import/export regression remain pending. The 26.52
  restart reset matches Mojang's MCPE-241720; the announced 26.60.24 Preview fix
  needs its own runtime test. See the [skin diagnosis](history/TESTING.md#october-20-skin-persistence-diagnosis).
- [Adventure-preview scenery (#5)](https://github.com/1JRobertson/bedrock-mac/issues/5):
  closed as not planned on November 2. The preview UI is outside the maintained
  launcher and its `4ed3a6f` source remains unavailable. Reopen if the source is
  provided; no model fix was claimed.
- [Xbox user-auth HTTP 400 (#12)](https://github.com/1JRobertson/bedrock-mac/issues/12):
  the panic/reporting fix is published. The reporter confirmed that the old
  zero-byte measurement was ambiguous; the underlying rejection remains unknown.
  Await the adapter revision and any existing sanitized diagnostic from the
  updated helper. See [the investigation](history/XBOX-AUTH-ISSUE-12.md).
- [Wine source verification (#18)](https://github.com/1JRobertson/bedrock-mac/issues/18):
  preview 3 names rejected files. The six reported GDK additions pass a fresh
  pinned reconstruction; await the actual rejected paths from the reporter.

## Repository security coverage

As checked November 2, private vulnerability reporting, secret scanning, push
protection and dependency alerts are enabled. GitHub's dependency graph includes
Cargo, Python and GitHub Actions inputs. Pinned and patched runtime sources still
need review when updated. CodeQL default setup is not configured and no code
analysis has been published; source tests do not provide that coverage.
The [dependency review](history/DEPENDENCY-AUDIT-2026-11-02.md) records the active
TLS/toolchain updates and why older backend/platform lock entries are scoped out
for the supported Mac helper.

## Acceptance record

Use [the manual test matrix](TESTING.md#manual-test-record). Record date,
source/app identity and hash, Mac/chip/RAM, macOS, exact game version, initial
data state, action and result. Preserve failures and remaining limits. Test
with disposable worlds and independent backups; never erase a user's saves or
Keychain to imitate a fresh installation.

Before advertising an app download, link its exact artifact, checksums,
corresponding-source/notices materials and separate source, clean-machine,
account, graphics, save/restore, update, multiplayer and soak results.
[Draft release notes](RELEASE_NOTES.md), [licensing](../THIRD_PARTY.md) and
[publishing](PUBLISHING.md) describe the remaining distribution work.
