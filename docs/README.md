# Documentation and repository map

Start with [the project README](../README.md) to build/play from source, or the
[user guide](USER_GUIDE.md) for a complete locally built app. The launcher handles
setup, sign-in and recovery; play uses vanilla Minecraft's own menus.

## Guides

| Task | Reference |
| --- | --- |
| Understand the current components and ownership | [Architecture](../CONTEXT.md) |
| Build, package or iterate locally | [Development](DEVELOPMENT.md) |
| Use low-level setup/account commands | [CLI reference](CLI.md) |
| Choose checks and record native acceptance | [Testing](TESTING.md) |
| Prepare a reviewed source export | [Publishing](PUBLISHING.md) |
| Review known gaps and artifact readiness | [Release readiness](RELEASE.md) · [Draft release notes](RELEASE_NOTES.md) |
| Check hardware/features | [Compatibility](COMPATIBILITY.md) |
| Understand runtime recovery and monitoring | [Stability](STABILITY.md) |
| Inspect measurements and experimental designs | [Performance evidence](PERFORMANCE.md) · [Research index](research/README.md) |
| Find dated tests, sessions and old artifacts | [History index](history/README.md) |
| Contribute safely | [Contributing](../CONTRIBUTING.md) · [Agent guidance](../AGENTS.md) |
| Review trust and licenses | [Security](../SECURITY.md) · [Third-party notices](../THIRD_PARTY.md) |

## Repository map

| Location | Purpose |
| --- | --- |
| `Start.command` | Public source-build/play entry point |
| [`client/`](../client/README.md) | Supported session, acquisition/account helper and data preparation |
| [`launcher/`](../launcher/BedrockLauncher.swift) | Native Mac interface and worker |
| [`tools/`](../tools/README.md) | Bootstrap, builders, probes, packaging, license collection and export |
| [`native/`](../native/README.md) | Graphics bridge, native probes and file-picker source |
| [`config/`](../config/README.md) | Reviewed dependency lock and release-runtime profile |
| `patches/` | Reproducible changes against exact upstream revisions |
| `tests/` | Isolated source/fixture tests and explicit native contracts |
| [`experiments/`](../experiments/README.md) | Default-off performance tools; separate from ordinary setup |
| [`legacy/`](../legacy/README.md) | Historical CrossOver path; separate prefix and helper |
| `LICENSES/` | Retained component notices and pinned public verification key |
| `docs/research/`, `docs/history/` | Detailed measurements and dated evidence |

Run documented commands from the repository root. Source paths moved into these
folders; generated source trees and data directories did **not** move. `sources/`,
`build/`, `runtime/`, `downloads/`, `game/`, `bottles/`, logs, update backups and
recovery directories are private generated/runtime state, not public source.

Source setup stores its game and saves under the checkout. A packaged app uses
`~/Library/Application Support/Bedrock for Mac/`; reorganization does not migrate
or refresh either installation. Keep data separate from source changes.
