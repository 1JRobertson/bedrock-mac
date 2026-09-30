# Standalone setup

This setup obtains each user's Windows Bedrock game through their own Microsoft account. It does not use CrossOver or distribute Minecraft, Microsoft runtime binaries, credentials, or licenses.

From this directory:

```sh
./standalone-setup.py --check
./standalone-setup.py --dry-run --threading --build-helper --download-game
```

Both commands are offline. They do not read Keychain or modify the current game. `--check` returns a nonzero status when required setup files are missing.

To prepare a new installation:

```sh
./standalone-setup.py --threading --build-helper
./standalone-setup.py --download-game --game-dir "$PWD/game" --market CA
```

The source build requires Git, Rust 1.98.0, Protocol Buffers (`protoc`), and the macOS Command Line Tools. The Microsoft GDK download is approximately 1.3 GB; Minecraft needs several additional gigabytes. The setup checks available space. `--jobs 4` is the default build parallelism.

An already prepared game is reused without account access. New downloads require a destination that does not exist. Close Minecraft and stop its account helper before downloading; setup refuses to replace an active `/tmp/xodus.sock` or overwrite an installation. Failed downloads discard only their own temporary directory. They do not resume game file transfers.

Sign in using the Microsoft account that owns Minecraft: Java & Bedrock for PC. `--market` accepts a two-letter country code and defaults to `CA`. Microsoft selects the currently available Windows package; game versions are therefore not pinned. A future game update may require new compatibility fixes.

One helper executable performs login, licensed download, executable preparation, and the Xbox service. Its credentials remain in macOS Keychain under `Minecraft Bedrock Standalone`; it does not reuse the experimental helper's Keychain entries. Rebuilding that executable can cause macOS to request Keychain access again. No account tokens or content keys are written to project files.

Finish building before signing in, then keep using that same helper binary. An incomplete or expired user session reopens sign-in on the next launch; cancelling sign-in returns an error. A denied Keychain read preserves the saved identity and fails rather than repeatedly provisioning another one. Existing device credentials are refreshed when their token expires. Migrating from the experimental helper requires exiting its game and stopping that helper first, then signing in once to the new namespace; credentials are not copied between executables.

The launcher may start the service with:

```sh
XODUS_LOG=off RUST_LOG=off ./sources/xodus/target/release/examples/standalone_helper --serve "$PWD/game"
```

Use the same binary for download and service. Each `--serve` start reacquires the signed-in account's real Microsoft content license for the installed package before opening the Xbox IPC service. A copied prepared executable does not replace account ownership. `--download GAME_DIR --serve-after` performs both in one process. Stop the service with Ctrl-C after exiting the game. An account lock prevents two standalone helpers from accessing the same saved session concurrently.

The helper preserves any existing Xbox socket and refuses to replace it. Use the launcher for recovery of a recorded dead helper's socket; an unknown or listening socket remains untouched.

`--threading` obtains Microsoft's [GDK April 2026 Update 4](https://github.com/microsoft/GDK/releases/tag/April-2026-Update-4-v2604.4.7897) archive. It verifies Microsoft's published archive digest, reads the exact Gaming Services x64 package member, and verifies the DLL before placing it in `runtime/xgameruntime.dll.threading`. An existing file with a different digest is preserved and rejected.

| File | SHA-256 |
| --- | --- |
| `GDK_2604.4.7897.zip` | `3da3f104fa66bb3ee1299b3dc8c0a3ecac1cb56a4cf04136b8595942272017eb` |
| `xgameruntime.dll.threading` | `aa611155057ebd01cf315ad702a4b5725aa9d5e6fad87732c956fe0a1e5fcfba` |

The helper uses Xodus commit `0670e25aeb0e0e9f800f8f2f4968ae3b681842a7` with the source patches and dependency lockfile in `patches/`. The game download uses Microsoft's package metadata and owner license, downloads into a private temporary directory, checks paths and file sizes, prepares encrypted executables using that license, and promotes the directory only after preparation succeeds.

An interrupted source clone leaves no incomplete final checkout. A complete GDK partial download is verified and recovered without another request. Installation promotion refuses to replace a destination created while setup was running.

Verified locally: helper compilation, offline installation checks, nested Microsoft DLL extraction, session expiry/cancellation decisions, preservation on denied credential access, safe socket handling, and interrupted-setup recovery. The offline tests use disposable fixtures and do not access Keychain or launch Minecraft:

```sh
python3 -m unittest discover -s tests -p test_standalone_setup.py -v
cargo +1.98.0 test --manifest-path sources/xodus/Cargo.toml --release --locked \
  -p xodus-cli --example standalone_helper
```

A fresh-account login/download and authenticated restart through this new helper have not yet been exercised. Wine, graphics, prefix installation, and gameplay validation are handled separately from this setup script.

## Native GameInput installation

The current Microsoft GameInput MSI stalls in its service configuration custom action under the standalone Wine build. `standalone-gameinput.py` reads the owned game's MSI directly, verifies its pinned checksum, and extracts four exact native x64 files by checksum. It emits a registry file for the launcher to import, including both `RedistDir` views and the real demand-start `GameInputRedistService` executable. It does not execute MSI custom actions or report registry installation as complete before import.

The launcher must stop only its separate Wine prefix before extraction:

```sh
./standalone-gameinput.py --prefix "$PWD/bottles/Bedrock-Standalone" \
  --msi "$PWD/game/Installers/GameInputRedist.msi" \
  --wineserver "$PWD/runtime/standalone/wine/bin/wineserver"
```

It refuses busy prefixes, CrossOver bottles, symbolic-link destinations, conflicting installed files, and unknown MSI versions. Import the emitted `bottles/Bedrock-Standalone/.standalone-gameinput.reg` using that prefix's Wine, then stop that prefix's server to flush its registry. Run the same command with `--check` for read-only verification of installed hashes and persisted registry entries; `--wineserver` is optional for this check. `--verify-payload` validates extraction entirely in memory.

The OLE/MSZIP parser is adapted from [BedrockOnLinux](https://github.com/Wyze3306/BedrockOnLinux) commit `7a315c836b7ae8068042bc466b0540c16ffe3a5e`; the script contains its full MIT copyright and license notice. Microsoft payload bytes are never included in the source release.
