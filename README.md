# Bedrock for Mac

Run your owned **Minecraft for Windows (Bedrock)** on an Apple Silicon Mac
with macOS 15 or later. No CrossOver subscription is required.

**LAN and online multiplayer.** The maintainer has played with friends on
Xbox and PS5 over LAN and online. Two online sessions and local world save
and reopen were recorded on an M4 Pro Mac mini running macOS 15.3.1. The
[gameplay record](docs/history/GAMEPLAY.md#repeated-cross-platform-play) has
the session details.

**Tested on an M1 Air.** We built source preview 6, downloaded Minecraft, and
played in a local world on a 16 GB M1 MacBook Air running macOS 26.6.2. Setup
required a Homebrew update. [M1 test](docs/RELEASE.md#m1-air-source-install-and-first-play)

[Download source preview 6](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.6)
and follow the [setup steps](#start-from-source). The first run builds the
tools needed to run the Windows game and downloads your owned copy.

## Start from source

On an **Apple Silicon Mac with macOS 15 or later**:

1. Extract the source release. You can also clone this repository or use
   **Code → Download ZIP**.
2. Keep the folder in a permanent location you control: it holds your game,
   settings, and saves. Do not replace or delete it when updating source.
   Source builds require a full path containing only ASCII letters, digits,
   `/`, `.`, `_`, `+` and `-` (for example, `~/git/bedrock-mac` after expanding `~`).
   See [build path requirements](docs/DEVELOPMENT.md#build-paths).
3. Double-click **Start.command**, or run `./Start.command` from Terminal in
   that folder. Keep Terminal open through setup and play.
4. Follow the Apple/Homebrew prompts and sign in with the Microsoft account
   that owns **Minecraft for Windows**. A console/mobile purchase alone is
   insufficient. If Minecraft asks, select **Sign in now**.

The first run installs missing build tools, fetches pinned sources, compiles
Wine and the account helper, validates the graphics memory fixes, and downloads
your owned game. It needs internet access, Rosetta, several GB of downloads,
and room for source/build outputs as well as the game. Build time and minimum
build-space requirements have not been measured. Apple Command Line Tools
installation asks you to press Return when it finishes.

Use **Start.command** again to play. It reuses a complete installation and
retries interrupted setup; interrupted game downloads restart. It does not
automatically update an installed game or runtime. Read-only status and
setup-only commands are available:

```sh
./Start.command --check
./Start.command --setup-only
./Start.command --market US  # Store country; default CA
```

If macOS blocks opening the script, follow [Apple's opening guidance](https://support.apple.com/en-us/102445)
after checking the source. See [the build guide](docs/DEVELOPMENT.md) for
manual setup steps and troubleshooting.

## Locally built app

Developers can [build a complete app and DMG](docs/DEVELOPMENT.md#build-a-complete-local-app).
Open that DMG, copy **Bedrock for Mac** to **Applications**, then choose
**Install & Play**. The bundle includes the runtime and saves its data
separately from the source checkout. Follow [the app user guide](docs/USER_GUIDE.md)
for sign-in, backups, and updates.

## Performance and experiments

[Performance measurements](docs/PERFORMANCE.md) cover CPU cost and frame rate
in development builds.

An optional [Mullion ray-tracing experiment](experiments/mullion/README.md)
demonstrated reflections and indirect lighting on the maintainer's M4 Pro Mac
with macOS 15.3.1. It includes GPU probes and a separate proof world; normal
startup does not enable it. Read the [results and known limits](experiments/mullion/RESULTS.md)
before opting in.

## Help and development

The [documentation index and repository map](docs/README.md) separate current
guides, supported source, build tools, experiments and dated evidence.

| Task | Guide |
| --- | --- |
| Use a locally built app, sign in, retry, or resolve Mac prompts | [User guide](docs/USER_GUIDE.md) |
| Back up worlds, update, restore, or uninstall | [Files and backups](docs/USER_GUIDE.md#your-files-backups-and-updates) |
| Check hardware and game-feature evidence | [Compatibility](docs/COMPATIBILITY.md) |
| Review candidate status and known limitations | [Release readiness](docs/RELEASE.md) · [Draft release notes](docs/RELEASE_NOTES.md) |
| Follow source-preview scope and planned work | [Source preview](docs/SOURCE_PREVIEW.md) · [Roadmap](docs/ROADMAP.md) |
| Build locally | [Development guide](docs/DEVELOPMENT.md) |
| Understand the runtime and historical gameplay | [Context](CONTEXT.md) · [Stability notes](docs/STABILITY.md) |
| Contribute or report a bug | [Contributing](CONTRIBUTING.md) · [Testing](docs/TESTING.md) |
| Review source exports, licenses, or security | [Publishing](docs/PUBLISHING.md) · [Notices](THIRD_PARTY.md) · [Security](SECURITY.md) |
| Work with a coding agent | [Agent guidance](AGENTS.md) |

Source-run worlds live in `<checkout>/bottles/Bedrock-Standalone`. Packaged-app
worlds live outside the application in
`~/Library/Application Support/Bedrock for Mac/bottles/Bedrock-Standalone`.
Quit Minecraft normally before backing up or replacing the app. There is no
automatic app/game updater or supported offline-launch mode. The current source
adds **Update Minecraft…** for manual game updates; live recovery testing is pending.

Original project code is **GPLv3**; upstream components retain their licenses.
Built on [WineGDK](https://github.com/Sightem/WineGDK),
[Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt), and
[Xodus](https://github.com/xodus-gaming/xodus).

Not affiliated with Microsoft, Mojang, Apple, or CodeWeavers.
Each player needs their own legitimate Windows-game entitlement.
