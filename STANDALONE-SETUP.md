# Standalone setup

This setup obtains each user's Windows Bedrock game through their own Microsoft account. It does not use CrossOver or distribute Minecraft, Microsoft runtime binaries, credentials, or licenses.

This is the developer/reference CLI guide. Players should start with the
[user guide](docs/USER_GUIDE.md); for a complete build from a fresh checkout,
follow [local development](docs/DEVELOPMENT.md). Commands here use checkout data
unless `BEDROCK_HOME` is set; the packaged app has a separate data directory.

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

The source build requires Git, Rust 1.98.0, Protocol Buffers (`protoc`), and the macOS Command Line Tools. Setup downloads only the required 197 MB Gaming Services member from Microsoft's pinned GDK archive; Minecraft needs several additional gigabytes. The setup checks available space. `--jobs 4` is the default build parallelism.

An already prepared game is reused without account access. New downloads require a destination that does not exist. Close Minecraft and stop its account helper before downloading; setup refuses to replace an active `/tmp/xodus.sock` or overwrite an installation. Failed downloads discard only their own temporary directory. They do not resume game file transfers.

Sign in using the Microsoft account that owns Minecraft: Java & Bedrock for PC. `--market` accepts a two-letter country code and defaults to `CA`. Microsoft selects the currently available Windows package; game versions are therefore not pinned. A future game update may require new compatibility fixes.

One helper executable performs login, licensed download, executable preparation, and the Xbox service. Its credentials remain in one macOS Keychain item, `account-v1`, under `Minecraft Bedrock Standalone`. Each process reads that item once and caches it. Previous builds used four separate entries; this build leaves those untouched and asks for Microsoft sign-in again rather than triggering four authorization dialogs to import them. Rebuilding this ad-hoc signed executable can still cause macOS to request Keychain access again. No account tokens or content keys are written to project files.

`--check-download GAME_DIR` checks catalog selection, download metadata, package parsing, disk space, and the account's content license without installing game files. It requires a nonexistent game destination and can request Keychain access. Known failure stages use credential-free `BEDROCK_ERROR` codes; logs omit raw service responses and signed download URLs.

Account writes use Security.framework's `SecItemAdd`/`SecItemUpdate` path. The
legacy keyring setter reads the current secret before every write, which can
request authorization repeatedly even when application-level reads are cached.
The direct update removes those hidden reads without changing Keychain access
permissions. macOS still controls authorization for the initial read and updates.

The native launcher owns one account helper for the entire Play action. On a
fresh installation it uses `--download --serve-after`, keeps that process alive
while the runtime is prepared, and reuses its Xbox service when Minecraft starts.
The helper stops when the game exits, setup fails, or setup is cancelled. Sign-in waits are bounded to 15 minutes; first downloads have a two-hour limit. Cancellation drops the active download and removes its temporary staging directory. Setup retries preserve the game and worlds. Previously download and
launch each started a helper, causing a second Keychain read during onboarding.
The integration test exercises this flow with a private socket and fails if more
than one helper is started. This does not test or override macOS Keychain dialogs.

The native app menu includes **Sign Out of Microsoft…**. The helper’s `--sign-out GAME_DIR` mode removes only user tokens and user identity from the account item, keeps the device identity, and never changes game files or worlds. It refuses while an account service is active.

The launcher may start the service with:

```sh
XODUS_LOG=off RUST_LOG=off ./sources/xodus/target/release/examples/standalone_helper --serve "$PWD/game"
```

Use the same binary for download and service. Each `--serve` start reacquires the signed-in account's real Microsoft content license for the installed package before opening the Xbox IPC service. A copied prepared executable does not replace account ownership. `--download GAME_DIR --serve-after` performs both in one process. Stop the service with Ctrl-C after exiting the game. An account lock prevents two standalone helpers from accessing the same saved session concurrently.

`--threading` retrieves the exact compressed Gaming Services ZIP member using an HTTPS byte-range request to Microsoft's [GDK April 2026 Update 4](https://github.com/microsoft/GDK/releases/tag/April-2026-Update-4-v2604.4.7897) archive. It requires HTTP 206, verifies the exact compressed length and SHA-256, checks the decompressed length, and verifies the original pinned DLL hash. Servers that ignore Range are rejected instead of downloading the full archive. An existing full GDK archive is still supported and verified against Microsoft's published digest. The verified DLL goes in `runtime/xgameruntime.dll.threading`; conflicting existing files are preserved and rejected.

The compressed member starts at byte `1101515484`, is `196592307` bytes long,
and has SHA-256 `f8d5f3ebe7339d9d65ebf4b4d68cb7a5281c0f944acafd613ccc68d7d908baed`.
These constants were extracted from the full archive after validating its pinned digest.

| File | SHA-256 |
| --- | --- |
| `GDK_2604.4.7897.zip` | `3da3f104fa66bb3ee1299b3dc8c0a3ecac1cb56a4cf04136b8595942272017eb` |
| `xgameruntime.dll.threading` | `aa611155057ebd01cf315ad702a4b5725aa9d5e6fad87732c956fe0a1e5fcfba` |

The helper uses Xodus commit `0670e25aeb0e0e9f800f8f2f4968ae3b681842a7` with the source patches and dependency lockfile in `patches/`. The game download uses Microsoft's package metadata and owner license, downloads into a private temporary directory, checks paths and file sizes, prepares encrypted executables using that license, and promotes the directory only after preparation succeeds.

The account/catalog/license client requires HTTPS. Game bytes use a separate client without account headers or cookies, preserving the URL supplied by the authenticated catalog. HTTP is accepted only for `assets1.xboxlive.com` and `assets2.xboxlive.com` on port 80, including redirects. Those Microsoft CDN names do not currently provide matching HTTPS certificates; rewriting their scheme causes setup to fail. TLS certificate validation remains enabled for HTTPS URLs. The package parser's existing segment checks do not provide complete verification of every unencrypted package section.

Verified locally: owner-account download and preparation on the development Mac, Microsoft sign-in through Minecraft’s welcome confirmation, helper compilation, offline installation checks, nested Microsoft DLL extraction, path traversal rejection, preservation of conflicting DLLs and symlinks, and refusal to access a second account session while the existing Xbox helper is running. A completely fresh account on a clean Mac has not yet been tested. Wine, graphics, prefix installation, and gameplay validation are handled separately from this setup script.

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
