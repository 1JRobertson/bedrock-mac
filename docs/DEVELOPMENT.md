# Local development

Start with [CONTEXT.md](../CONTEXT.md) for component ownership and
[CONTRIBUTING.md](../CONTRIBUTING.md) for the review workflow. All commands here
run from the repository root on the local Mac. The standalone build does not
require CrossOver or an Apple Developer membership.

## Prerequisites

The documented build host is Apple Silicon. The currently tested complete bundle
requires macOS 26. Swift/DXMT target macOS 15, but the minimum OS of the assembled
app depends on every native binary, including Python and Wine dependencies.

Install Apple's Command Line Tools and Rosetta, Git, a Python 3.12+ interpreter
for packaging, Rust/rustup, and Homebrew under `/opt/homebrew`. The source tools
otherwise support Python 3.9+; CI exercises 3.12 and 3.14. Homebrew's LLVM,
Bison, GnuTLS, FreeType, and Protocol Buffers are build dependencies. The scripts
use their `/opt/homebrew/opt/...` paths; an Intel Homebrew installation is not a
drop-in replacement.

If these tools are not installed yet, start with the official
[Homebrew installation guide](https://brew.sh/) and
[Rust/rustup installation guide](https://rust-lang.org/tools/install/). Reopen
Terminal after configuring their PATH entries. A Homebrew Python can provide
the packaging interpreter (`brew install python@3.14`); check which `python3`
your shell selects before creating the venv.

With Homebrew and rustup already installed:

```sh
xcode-select --install  # only if Command Line Tools are missing
brew install llvm bison gnutls freetype protobuf
rustup toolchain install 1.98.0 --profile minimal
```

Check the selected tools before a long build:

```sh
uname -m
sw_vers -productVersion
xcrun --find clang
xcrun --find swiftc
python3 --version
rustup run 1.98.0 rustc --version
protoc --version
/usr/bin/arch -x86_64 /usr/bin/true
```

The last command must exit successfully for the Intel runtime to work. If
Rosetta is missing, follow [Apple's instructions](https://support.apple.com/en-us/102527).
The launcher only checks for Rosetta; it does not install it for the user.

Building Wine and Rust uses much more storage than the player's 8 GB setup
check. Inspect `df -h .`, leave room for source, compiler output, archives, and
both app/DMG copies, and use a separate backup location for worlds. No measured
minimum build-space requirement or build-time guarantee is established.

## Build a complete local app

Clone the repository into a directory you control, then run:

```sh
git clone https://github.com/1JRobertson/bedrock-mac.git
cd bedrock-mac
python3 bootstrap-sources.py
STANDALONE_JOBS=3 ./build-standalone-wine.sh
./build-standalone-graphics.sh --wine-runtime "$PWD/runtime/standalone/wine"
python3 standalone-setup.py --build-helper --jobs 4
python3 -m venv build/packaging-env
build/packaging-env/bin/python -m pip install -r packaging-requirements.txt
python3 package-launcher.py
python3 build-dmg.py
```

Use a Python 3.12+ `python3` when creating `build/packaging-env`. If the venv
already uses an older Python, preserve/move it and create a new one with the
intended interpreter. Installing a newer system Python does not upgrade an
existing venv.

| Step | Result and behavior |
| --- | --- |
| Bootstrap | Fetches pinned WineGDK and Xodus into `sources/`, applies tracked patches and Cargo lockfile; refuses an existing destination |
| Wine build | Compiles WineGDK in `build/standalone-wine`, installs to `runtime/standalone/wine`; downloads a pinned archive for portable dependency dylibs |
| Graphics staging | Downloads/verifies pinned DXMT, installs its Wine overlay, and records original DLL backups |
| Helper build | Copies `standalone-helper.rs` into Xodus and builds its release example with the locked dependencies |
| Package | Builds Swift/icon and frozen Python worker; copies runtime/helper, signs locally, records resource hashes and actual OS requirement |
| DMG | Creates `build/Bedrock for Mac.dmg` containing the app and an Applications shortcut; verifies the image |

The complete app is `build/packaged/Bedrock for Mac.app`. It includes build
outputs for the open-source runtime but no game, Microsoft DLLs, Keychain data,
worlds, or development checkout. First Play obtains the required Microsoft
component and owned game. Build scripts never imply that a binary is cleared for
public redistribution; see [THIRD_PARTY.md](../THIRD_PARTY.md).

Do not run the Wine/graphics builds or replace an app while a game uses those
components. Quit Minecraft normally and let its account helper finish first.
The Wine and helper builders have active-process guards; still check which app
copy and runtime you are testing.

## Iterate without losing a working build

`./build-launcher.sh` creates `build/Bedrock for Mac.app`, a development front end
that points at this checkout and uses `/usr/bin/python3`. It is useful for Swift
and worker changes after preparing the local runtime, but is not a portable app.
`python3 launcher/setup.py --status` inspects its installation without sign-in.

The packager refuses to overwrite an existing output. Use a new output name:

```sh
python3 package-launcher.py --output 'build/iteration-2/Bedrock for Mac.app'
python3 build-dmg.py --app 'build/iteration-2/Bedrock for Mac.app' \
  --output 'build/Bedrock for Mac-iteration-2.dmg'
```

Choose a fresh suffix for each retained build. The packager rebuilds its
intermediate `build/frozen`, `build/pyinstaller`, and development launcher, so
do not run two packaging jobs concurrently. A packaged app copies its components;
subsequent edits in the checkout do not update that app. Repackage to test them.

After a Wine rebuild, rerun graphics staging with `--wine-runtime`: Wine's
installed D3D DLLs otherwise shadow DXMT. For helper source changes, use
`standalone-setup.py --build-helper`; `build-helper.sh` compiles the historical
`bedrock_helper`, not the native launcher's `standalone_helper`.

Rebuilding an ad-hoc helper can change Keychain authorization. To test remembered
access, launch the same helper bytes twice after the user authorizes it; do not
rebuild between attempts. Never change Keychain permissions just to force a pass.

## Command-line setup and diagnostics

The source CLI works in the checkout by default. Do not use it to infer the state
of a packaged app's separate data directory. To read that installation's status:

```sh
BEDROCK_HOME="$HOME/Library/Application Support/Bedrock for Mac" \
  python3 standalone-setup.py --check
```

`--check` is local and returns nonzero when installation is incomplete. It does
not access Microsoft or Keychain. `--dry-run` prints requested actions without
performing them. For a source installation, these are the actual setup stages:

```sh
python3 standalone-setup.py --threading
python3 standalone-setup.py --download-game --game-dir "$PWD/game" --market CA
python3 standalone.py prepare
python3 standalone.py launch --market CA
```

Download and launch can sign in and contact Microsoft; they are not offline
checks. The separate CLI invocations also use separate helper sessions. Use the
native launcher when testing its single-session onboarding UX. A custom
`--game-dir` must be supplied consistently to setup and runtime commands. A
different game directory cannot silently replace an existing `G:` drive mapping
in the same prepared prefix.

For optional probes, after installing the owned game and runtime:

```sh
./build-standalone-probes.sh
python3 standalone.py probe graphics
```

The graphics probe exercises the local Wine prefix. The `account`, `store`, and
`privileges` probes also use the account helper and may prompt/contact Microsoft.
See [STANDALONE-SETUP.md](../STANDALONE-SETUP.md),
[graphics notes](../standalone-graphics-notes.md), and [testing](TESTING.md).

## Build failures

| Failure | Check |
| --- | --- |
| Bootstrap destination exists | Run `python3 bootstrap-sources.py --check`; preserve local changes before preparing a new source tree. Do not fetch a different branch into the pinned checkout to silence a mismatch. |
| Cargo lock or source patch mismatch | Compare tracked patches, `patches/Cargo.lock`, and the pinned source check. Keep `--locked`; update provenance and checksums intentionally. |
| `protoc` missing | Check the `protobuf` installation and PATH, or the intended `PROTOC` executable. |
| Wine configure/compile/install failure | Read `build/standalone-wine/configure.log`, `build.log`, or `install.log`; confirm the required Homebrew paths and Rust toolchain. |
| DXMT mismatch after runtime rebuild | Reapply the graphics overlay with `--wine-runtime` before preparing/launching. |
| Package dependency missing | Build Wine, stage DXMT, build the standalone helper, and install the packaging requirements into the expected venv. |
| Package/DMG destination exists | Choose a new output path; keep the running or last working copy. |
| New bundle needs a newer macOS | Inspect its `Contents/Info.plist` and native dependency targets. Lowering the plist alone does not make it compatible. |

Validate the appropriate boundaries in [TESTING.md](TESTING.md), then update the
[source inventory](PUBLISHING.md#update-the-source-inventory). A successful build
is not evidence of a fresh-account download, gameplay, or a clean-Mac install.
