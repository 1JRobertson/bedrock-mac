# Bedrock for Mac

**Source preview; no public installer yet.** Local RC4 includes the helper that
passed verified acquisition outside the app. Native first-run, update, gameplay
and clean-M1 qualification remain open in the [release record](docs/RELEASE.md).

Run your owned **Minecraft for Windows (Bedrock)** on an Apple Silicon Mac,
using WineGDK, DXMT, and Xodus. The launcher is native macOS; the Windows game
runs through Wine and Rosetta. No CrossOver subscription is required.

**Source preview — no public notarized installer yet.** A new local release
candidate is being qualified. Download links remain pending; GitHub's source ZIP
is not an installable app. See [release readiness](docs/RELEASE.md).

## Play

With a complete, locally built app:

1. Open the DMG and drag **Bedrock for Mac** into **Applications**.
2. Open the app and choose **Install & Play**.
3. Sign in with the Microsoft account that owns **Minecraft for Windows**.
4. Let setup finish. If Minecraft asks, select **Sign in now**.

Later launches show **Play**. Players using the complete bundle do not need
Homebrew, Python, compilers, or a separate Wine install. Minecraft and your
account are not included in the app.

You need Apple Silicon, Rosetta, internet access, a Windows-game entitlement,
and at least 8 GB free for initial setup, plus space for worlds and backups.
Local RC4 requires **macOS 15.0 or later**, based on its complete native-binary
audit. Clean-M1 gameplay remains untested; later candidates need their own audit.
See the [compatibility table](docs/COMPATIBILITY.md) before testing.

## What has been tested?

Earlier development builds ran local worlds and user-confirmed Xbox/PS5
friend-world sessions on an M4 Pro. Those observations do not qualify a new
packaged build. Clean M1 installation, current-candidate multiplayer, app
replacement, and long sessions are separate release gates.

Performance work has reduced measured CPU cost in bounded development tests.
It does **not** establish a cumulative FPS improvement, lower power use, or a
speedup for the release candidate. [Performance evidence](docs/PERFORMANCE.md)
explains the measurements and their limits. Native ARM game execution is a
separate research track, not a feature of this Windows-runtime preview.

## Help and development

| Task | Guide |
| --- | --- |
| Install, sign in, retry setup, or resolve Mac prompts | [User guide](docs/USER_GUIDE.md) |
| Back up worlds, update, restore, or uninstall | [Files and backups](docs/USER_GUIDE.md#your-files-backups-and-updates) |
| Check hardware and game-feature evidence | [Compatibility](docs/COMPATIBILITY.md) |
| Review candidate status and known limitations | [Release readiness](docs/RELEASE.md) · [Draft release notes](docs/RELEASE_NOTES.md) |
| Build locally | [Development guide](docs/DEVELOPMENT.md) |
| Understand the runtime and historical gameplay | [Context](CONTEXT.md) · [Stability notes](docs/STABILITY.md) |
| Contribute or report a bug | [Contributing](CONTRIBUTING.md) · [Testing](docs/TESTING.md) |
| Review source exports, licenses, or security | [Publishing](docs/PUBLISHING.md) · [Notices](THIRD_PARTY.md) · [Security](SECURITY.md) |
| Work with a coding agent | [Agent guidance](AGENTS.md) |

Worlds live outside the application in
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
