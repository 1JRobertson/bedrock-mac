# Bedrock for Mac

Play your owned Windows edition of Minecraft Bedrock on an Apple Silicon Mac.
Built with WineGDK, DXMT, and Xodus. No CrossOver subscription.

**Open-source preview.** The native app works on the development Mac; a public,
notarized app is not available yet. This repository contains the source and build
scripts. See [release readiness](docs/RELEASE.md) for tested behavior and remaining
release work.

## The app

1. Open the disk image and drag **Bedrock for Mac** into **Applications**.
2. Open the app and click **Install & Play**.
3. Sign in with the Microsoft account that owns **Minecraft for Windows**.

The app downloads the game and its required Microsoft component, then opens
Minecraft. Later launches show **Play**. Minecraft may show **Sign in now** on
its first welcome screen; select it to use the account you just signed in with.

Setup can be cancelled and retried. Completed installation steps are reused;
interrupted game downloads restart. **Bedrock for Mac → Sign Out of Microsoft…**
lets you change accounts without deleting your game or worlds.

Requirements: Apple Silicon, Rosetta, an internet connection, a Minecraft for
Windows license, and at least 8 GB free for setup. The current local packaged
build requires **macOS 26 or later**. The Swift interface and DXMT target macOS
15; every binary must meet that target before an older-macOS package is advertised.

For now, developers can build the app below. These steps are build instructions,
not extra tools that users of a packaged app need to install.

## Build locally

Build tools: Apple Command Line Tools, Git, Python 3.9+, Rust **1.98.0**, and
Homebrew `llvm`, `bison`, `gnutls`, `freetype`, and `protobuf`. The scripts currently
expect Homebrew at `/opt/homebrew`. Python **3.12+** is required for packaging.

```sh
git clone https://github.com/1JRobertson/bedrock-mac.git
cd bedrock-mac
python3 bootstrap-sources.py
./build-standalone-wine.sh
./build-standalone-graphics.sh --wine-runtime "$PWD/runtime/standalone/wine"
python3 standalone-setup.py --build-helper
python3 -m venv build/packaging-env
build/packaging-env/bin/python -m pip install -r packaging-requirements.txt
python3 package-launcher.py
python3 build-dmg.py
```

The output is `build/Bedrock for Mac.dmg`. The app includes its Python worker,
Wine, DXMT, and account helper. It never installs Homebrew, downloads compilers,
or builds source on a player's Mac. Game files, Microsoft DLLs, accounts, and
worlds are **not** included. They are obtained or created on the user's Mac.

The default package destination must not already exist. Pass
`--output /path/to/Bedrock\ for\ Mac.app` to build another app without replacing a
running copy; pass that path to `build-dmg.py --app` and choose a new `--output`.

For a development launcher tied to your checkout, use `./build-launcher.sh`.
For command-line setup, probes, and download details, see
[STANDALONE-SETUP.md](STANDALONE-SETUP.md).

## Help

**macOS blocks the downloaded app.** Local builds use ad-hoc signatures and are
not notarized. GitHub hosting does not change that. Follow
[Apple's guidance for opening apps](https://support.apple.com/en-us/102445) only
if you trust the source. Do not disable Gatekeeper globally.

**Rosetta is missing.** See [Apple's Rosetta instructions](https://support.apple.com/en-us/102527).
The launcher checks for Rosetta before starting account setup.

**Keychain requests access.** Microsoft credentials stay in macOS Keychain.
One account helper reads one saved item per session and reuses it through setup
and play. Rebuilding an ad-hoc signed helper changes its identity and may require
new authorization. **Allow** grants access once; **Always Allow** remembers
permission for that helper. Keychain access is separate from permission to open a
downloaded app; zero-prompt upgrades have not been verified. See
[Apple’s Keychain explanation](https://support.apple.com/guide/keychain-access/kyca1243/mac).

**Setup failed.** Click **Try Again**. Closing Microsoft sign-in returns to the
launcher; **Cancel** stops setup. Use **Help → Open Setup Logs** for diagnostics.
If an existing game directory is incomplete, quit the app and rename the `game`
folder in the data directory before retrying. Keep the old folder until you have
verified the replacement; never remove `bottles` to repair a download.

**Where are my worlds?** Packaged app data lives in
`~/Library/Application Support/Bedrock for Mac/`. The Wine prefix is
`bottles/Bedrock-Standalone`; worlds are inside that prefix's user profile under
`AppData/Roaming/Minecraft Bedrock`. Updating the app or signing out keeps these
files. Back up the data directory before experimenting with builds. The older
CrossOver setup uses a separate prefix; it does not migrate automatically.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and bug reports,
[docs/PUBLISHING.md](docs/PUBLISHING.md) for reviewed source exports, and
[docs/LEGACY.md](docs/LEGACY.md) for the earlier CrossOver implementation.

Original project code is **GPLv3**. Upstream components retain their licenses;
see [THIRD_PARTY.md](THIRD_PARTY.md). Built on
[WineGDK](https://github.com/Sightem/WineGDK),
[Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt), and
[Xodus](https://github.com/xodus-gaming/xodus).

Not affiliated with Microsoft, Mojang, Apple, or CodeWeavers. Minecraft is not
included; each player needs their own legitimate Windows license.
