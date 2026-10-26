# Roadmap

The goal is reliable setup and recovery that opens **vanilla Minecraft**.
These are acceptance gates, not promised dates or platform guarantees.

| Next step | Done when |
| --- | --- |
| Qualify source setup | A clean Apple Silicon Mac completes `Start.command`; record chip/RAM, macOS, revision, build time/space, sign-in, download, retry and save/reopen. An M1 Air report alone does not close this gate. |
| Verify the compiled party fix | The exact rebuilt WinHTTP artifact passes Minecraft party creation/leave/recreate, invite reception, party joining and friend-world joining. The temporary in-game correction and isolated regression tests are supporting evidence. |
| Qualify a distributable app | A specific app passes first-run, update/recovery, save/restore, multiplayer and extended-session checks; corresponding source/notices, signing, notarization and downloaded-app checks are complete. |

The [source preview](SOURCE_PREVIEW.md) gives contributors a versioned baseline.
[Release readiness](RELEASE.md) tracks binary gates; [compatibility](COMPATIBILITY.md)
separates source behavior, historical gameplay and current-candidate evidence.
Mullion ray tracing and native ARM game execution remain separate research tracks.
