# Bedrock for Mac

Run your owned **Minecraft for Windows (Bedrock)** on an Apple Silicon Mac,
using WineGDK, DXMT, and Xodus. The launcher is native macOS; the Windows game
runs through Wine and Rosetta. No CrossOver subscription is required. Setup
gets you to vanilla Minecraft, which keeps its own worlds, packs, settings and
friends menus.

**Open-source preview.** Build scripts are available now; there is no public
notarized app or downloadable installer. Local app candidates have separate
[release checks](docs/RELEASE.md).

## Start from source

On an **Apple Silicon Mac with macOS 15 or later**:

1. Clone this repository, or choose **Code → Download ZIP** and extract it.
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
after checking the source. A complete first run on a clean Mac still needs
qualification. See [the build guide](docs/DEVELOPMENT.md) for manual stages,
packaging and setup failures, and [compatibility](docs/COMPATIBILITY.md) for
what has actually been observed.

## Locally built app

Developers can [build a complete app and DMG](docs/DEVELOPMENT.md#build-a-complete-local-app).
Open that DMG, copy **Bedrock for Mac** to **Applications**, then choose
**Install & Play**. The complete bundle includes its runtime and build outputs;
players using it do not need build tools. Its data lives separately from the
source checkout. Follow [the app user guide](docs/USER_GUIDE.md) for sign-in,
backup and manual update actions. Local RC4's audited minimum OS is 15.0;
new bundles need their own audit and gameplay qualification.

## What has been tested?

The maintainer estimates **10+ total hours playing with Xbox and PlayStation
friends** across multiple sessions. Development testing also verified local-world
saving and reopening. The [gameplay evidence](docs/history/GAMEPLAY.md#repeated-cross-platform-play)
includes two monitored friend sessions on an **M4 Pro Mac mini with 24 GB RAM**.
The maintainer also reports it working on an **M1 MacBook Air with 16 GB RAM**;
its exact OS, source/app revision, and test scenarios have not been recorded.

Fresh installation on an M1, multiplayer with the new packaged candidate, app
replacement, and extended candidate sessions remain separate release checks.

Performance work has reduced measured CPU cost in bounded development tests.
It does **not** establish a cumulative FPS improvement, lower power use, or a
speedup for the release candidate. [Performance evidence](docs/PERFORMANCE.md)
explains the measurements and their limits. Native ARM game execution is a
separate research track, not a feature of this Windows-runtime preview.

## Help and development

The [documentation index and repository map](docs/README.md) separate current
guides, supported source, build tools, experiments and dated evidence.

| Task | Guide |
| --- | --- |
| Use a locally built app, sign in, retry, or resolve Mac prompts | [User guide](docs/USER_GUIDE.md) |
| Back up worlds, update, restore, or uninstall | [Files and backups](docs/USER_GUIDE.md#your-files-backups-and-updates) |
| Check hardware and game-feature evidence | [Compatibility](docs/COMPATIBILITY.md) |
| Review candidate status and known limitations | [Release readiness](docs/RELEASE.md) · [Draft release notes](docs/RELEASE_NOTES.md) |
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
