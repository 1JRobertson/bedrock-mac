# Release readiness

Updated October 21, 2026. **The public project is a source preview.** There is
no public notarized app/installer. Source PRs do not publish or qualify binaries.
The intended player experience is open the app, complete required setup/sign-in,
and reach vanilla Minecraft.

## Current gates

| Area | Recorded evidence | Still required |
| --- | --- | --- |
| Source checks | Dated checks in the [source audit](history/AUDIT-2026-10-21.md); current PRs record their own final source revision and results | Tests appropriate to each new change; disclose unavailable hosted CI |
| Runtime construction | Pinned-source v4 replay and exact-bridge graphics probes passed historically | Qualify the runtime selected for each new app |
| Ownership/download | Exact RC4 helper completed verified owner-account acquisition outside the app | New artifact's native first-run, retry and download cancellation |
| App/DMG | Local RC4 resource, notice-copy, signature and complete minimum-OS audit passed | Rebuild/audit any changed app; verify its exact artifact |
| Saves and updates | Historical development save/reopen and synthetic update/recovery checks | Candidate save/reopen/backup restore and actual game upgrade/recovery |
| Multiplayer/stability | User reports and two monitored friend sessions in [gameplay history](history/GAMEPLAY.md#repeated-cross-platform-play) | Candidate join/disconnect/rejoin, active Realm entry and extended session |
| Clean-machine/M1 | Maintainer reports it working on an M1 Air, 16 GB; exact OS/revision/scenarios unrecorded | Fresh-machine setup and artifact-specific acceptance receipt |
| Distribution | Source-built dependency receipts and collected notices exist | Final binary corresponding-source/build mapping; Developer ID/notarization and downloaded-app checks |

The maintainer reports exhausted GitHub Actions minutes. A baseline CI pass
cannot qualify a later commit; each PR must state its actual local checks and
any unavailable hosted jobs. Native test gaps remain visible even when a source
change is ready for review.

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
  the referenced `4ed3a6f` preview source is absent here. The issue stays open;
  a reproducible source is needed to verify a fix.

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
