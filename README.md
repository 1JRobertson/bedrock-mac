# Bedrock for macOS

An experimental launcher and compatibility setup for running the owned Windows
edition of Minecraft Bedrock on Apple Silicon Macs, using WineGDK and DXMT.
CrossOver is not required. This repository provides source, patches, and build
scripts; users obtain Minecraft through their own Microsoft account.

Built on [WineGDK](https://github.com/Sightem/WineGDK),
[Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt),
[Xodus](https://github.com/xodus-gaming/xodus), and the additional upstream work
credited in [THIRD_PARTY.md](THIRD_PARTY.md). Original project code is GPLv3;
upstream files and patches retain their documented licenses.

## Standalone runtime

A CrossOver-free build combines source-built WineGDK, upstream DXMT,
and the unified Microsoft account helper. The user confirmed working gameplay
on September 29, 2026, on an M4 Pro Mac mini running macOS 15.3.1.
The running game loads our Wine 11.8 runtime and DXMT v0.80, with no CrossOver
or D3DMetal files mapped. Minecraft 1.26.5203.0 uses Direct3D 11 at feature level 11.1.

Hardware rendering and presentation, cryptography, certificate-verified HTTPS,
Xbox account lookup, Store callbacks, and native GameInput installation pass.
A non-empty standalone world save exists. An online connection to the Lifeboat
featured server was verified, including entry into its lobby with other players.
Realms authentication and the joined-Realm list also work; entering an active
Realm remains untested. Reopening the local save, keyboard movement, saving,
and normal application exit were verified on September 30. PS5 friend sessions
and a complete fresh-machine installation remain untested. The new standalone
helper passed first Microsoft sign-in, owner-license verification, Xbox/PlayFab/
Realms token checks, and an authenticated restart without another sign-in. The
earlier gameplay tests reused the original unified helper. The normal launcher
was then retested with the new helper, refreshed-auth runtime, and corrected
graphics bridge together: Lifeboat login, lobby rendering, movement, and normal
disconnect passed. The Video settings fullscreen toggle, input while fullscreen,
and return to the original window size also passed.
Controller hardware, audible sound, Marketplace purchases, and extended online
sessions have not been validated.

An overnight session froze after about nine hours with roughly 20 GB of native
small-object allocations. Two native DXMT memory leaks were subsequently fixed:
temporary display-query objects and unreleased ColorSync profiles/tags. In a
five-minute Minecraft comparison, small native allocation growth fell from about
7.4 MB to 0.36 MB. Local-world rendering and saving passed with the corrected
bridge. These short tests do not establish that the overnight freeze is resolved;
all-day stability remains unverified.

Build prerequisites on Apple Silicon: macOS 15 or later, Rosetta, Apple Command
Line Tools, Git, Python 3.9+, Rust toolchain `1.98.0`, and Homebrew `llvm`, `bison`,
`gnutls`, `freetype`, and `protobuf` (for `protoc`). The current scripts use Homebrew's `/opt/homebrew`
installation. A clean-machine installation has not yet been tested.

Clone the source repository:

```sh
git clone https://github.com/1JRobertson/bedrock-mac.git
cd bedrock-mac
```

Build, prepare, and launch:

```sh
python3 bootstrap-sources.py
./build-standalone-wine.sh
./build-standalone-graphics.sh --wine-runtime "$PWD/runtime/standalone/wine"
python3 standalone-setup.py --build-helper --threading --download-game
./build-standalone-probes.sh
python3 standalone.py prepare
python3 standalone.py probe graphics
python3 standalone.py probe account
python3 standalone.py probe store
python3 standalone.py probe privileges
python3 standalone.py launch
```

Existing prepared source trees can be checked with
`python3 bootstrap-sources.py --check`. The setup command verifies and reuses an
existing prepared Windows game. A new installation opens Microsoft sign-in and
requires an account that owns the Windows PC game. Downloads come from the
vendors; game files, credentials, and Microsoft DLLs are excluded from source
exports.

The standalone launcher is **Launch Standalone.command**. Its prefix and saves
live under `bottles/Bedrock-Standalone`; it does not import existing worlds.
It requests the Direct3D 11 path because DXMT does not implement Direct3D 12.
The live CrossOver game must be closed before testing the standalone game.
The input setup extracts four checksum-verified files from the bundled Microsoft
GameInput MSI and registers its service. This avoids an MSI custom action that
stalls under standalone Wine. An unknown installer version is rejected for review.

After rebuilding Wine, rerun the graphics installer: Wine's installed builtin
DLLs take precedence over `WINEDLLPATH`, so DXMT must also be installed there.
The launcher verifies the five installed DXMT files against the staged copies.

The optional native graphics-memory fix can be built with Command Line Tools,
without rebuilding the upstream shader compiler. Close Minecraft, then run:

```sh
./build-standalone-dxmt-unix.sh
./build-standalone-dxmt-unix.sh --validate
./build-standalone-dxmt-unix.sh --stage-existing-runtime "$PWD/runtime/standalone/wine"
```

For checkouts prepared before DXMT was added to the source bootstrap, first run
`python3 bootstrap-sources.py --project dxmt` if `sources/dxmt` is absent.

Validation runs GPU readback, texture, and discard tests in an isolated runtime.
Staging requires those tests to match the exact built files and backs up the
original library. The launcher verifies both installed graphics libraries.
See [standalone-graphics-notes.md](standalone-graphics-notes.md) for details.

```sh
python3 standalone.py check
python3 standalone-setup.py --check
```

For source licensing, upstream credit, and a reviewed export, see
[THIRD_PARTY.md](THIRD_PARTY.md) and [docs/PUBLISHING.md](docs/PUBLISHING.md).

## Online permission checks

The initial runtime returned `E_NOTIMPL` for every multiplayer-permission check,
which produced Minecraft's **Fox / Prerequisites-4** error before connecting.
`standalone-wine-user-privileges.patch` reads authenticated Xbox `prv` and `agg`
claims, checks exact privilege IDs and expiration, and preserves those claims
when a different service needs its own token. Missing, malformed, or expired
claims never grant access. Account restrictions remain enforced.

`python3 standalone.py probe privileges` checks the current account's real
permissions and Xbox/PlayFab/Realms token generation without printing credentials.
The parser tests in `tests/xuser-claims.c` cover grants, denials, malformed
claims, exact ID matching, and UTC expiration; all 31 checks pass. Rebuild probes
with `./build-standalone-probes.sh`, then run `python3 standalone.py probe claims`.

Realms uses a separate XSTS audience. `standalone-wine-xuser-realms.patch` maps
its three known HTTPS API hosts to `https://pocket.realms.minecraft.net/` so
the runtime requests a token for the correct service. The 19 routing tests
reject lookalike and unrelated hosts. Run all 50 offline claim and routing
checks, plus 18 token-cache lifetime checks, with
`bash tests/run-xuser-tests.sh`; see [tests/XUSER.md](tests/XUSER.md).

`standalone-wine-xuser-token-refresh.patch` renews expiring Xbox tokens and
policy claims, honors `ForceRefresh`, and repairs the UTF-16 request context.
An isolated live test verified cache reuse, forced renewal, expiry of XSTS and
parent tokens, policy renewal, and UTF-16 requests against Microsoft's services.
It expires only the probe's own cached timestamps and never fabricates claims.

The launcher recovers a crashed account helper's private socket only when its
recorded process has exited and the socket refuses connections. Unrecognized
or listening endpoints are preserved. Incomplete sign-in times out after five
minutes and can be retried by launching again.

## Earlier CrossOver configuration

- Mac mini M4 Pro, macOS 15.3.1, Rosetta.
- Windows game 1.26.5203.0 downloaded through the signed-in Microsoft account.
- CrossOver 26.3 trial runs Windows programs. The trial lasts 14 days.
- D3DMetal renders the game. DXMT also passed a hardware DirectX 11 device probe.
- Custom WineGDK DLL and macOS bridge compile and load; the signed-in Xbox user resolves successfully.
- The 41% loading stall and 82% crash are fixed. The game loads into a playable world.
- Mouse/keyboard input, movement, crafting, and block breaking work; the user confirmed normal gameplay on September 29, 2026.
- A non-empty world save exists on disk. Reopening that save and multiplayer have not been tested.

The combined `bedrock_helper` owns Microsoft login, executable preparation, and the Xbox account service. Its credentials stay in macOS Keychain under `Minecraft Bedrock Mac`. A process-local cache avoids repeatedly asking Keychain for the same entry. Authentication and license tokens are not printed or saved in project files.

## Earlier CrossOver launcher

Double-click **Launch Bedrock.command**. It starts or reuses the local account helper, waits for it to be ready, and launches the game. This launch path has reached gameplay with the existing signed-in helper; a new helper session can still require Keychain approval. Use this launcher so the required runtime overrides and game working directory are applied.

Client worlds are stored under `bottles/Bedrock-Mac/drive_c/users/crossover/AppData/Roaming/Minecraft Bedrock/`, inside the account's `games/com.mojang/minecraftWorlds` directory. They are separate from the dedicated server's worlds.

To check the installation without launching:

```sh
./launch.py --check
```

## Diagnostic commands

Run the helper from this directory, leaving it open for the game:

```sh
umask 077
XODUS_LOG=off RUST_LOG=off ./sources/xodus/target/release/examples/bedrock_helper "$PWD/game" > logs/bedrock-helper.log 2>&1
```

Once `/tmp/xodus.sock` exists and the helper reports that preparation finished:

```sh
./run-windows.sh "$PWD/game/runtime-auth-probe.exe"
./run-windows.sh "$PWD/game/Minecraft.Windows.exe"
```

Stop the helper with Ctrl-C after closing the game. Do not run multiple account helpers at once.

`build-runtime.sh`, `stage-runtime.py`, `build-helper.sh`, and `build-probes.sh` rebuild the local components from the prepared sources. Exit the game and helper before rebuilding. A changed helper binary may require macOS to authorize Keychain access again.

The bottle lives under `bottles/Bedrock-Mac`; a symlink in the standard CrossOver Bottles directory makes it visible in CrossOver. Graphics is set to D3DMetal. The server files and worlds in the parent Bedrock directory are separate.

## Startup fixes

- Native overrides for WineGDK's `twinapi.appcore`, `windows.ui.core.textinput`, `windows.web`, and `wintypes`, with the activation mappings in `winrt.reg`. The `wintypes` capability query avoids the fatal `E_NOTIMPL` at 82%.
- `minecraft-store-callback.patch` completes the unsupported game-license query with `E_NOTIMPL` on the caller's task queue. The previous immediate stub stranded Minecraft at 41%. This reports a missing Store capability; it does not fabricate ownership or alter the game's licensing checks. The executable is prepared using the account's real Microsoft license.
- Microsoft's bundled GameInput redistributable and the missing directory registration in `gameinput.reg`.

After staging the runtime, register the classes and install the bundled input component:

```sh
./run-windows.sh reg import "$PWD/winrt.reg"
./run-windows.sh msiexec /i 'Y:\git\minecraft\bedrock\macos-client\game\Installers\GameInputRedist.msi' /qn /norestart
./run-windows.sh reg import "$PWD/gameinput.reg"
```

The MSI path above is for this Mac's existing Wine drive mapping. For another checkout, use that bottle's Windows path to the same bundled installer. Restart Minecraft after installation.

`store-callback-probe.c` verifies that both thread-pool and manually dispatched completion queues receive exactly one callback, report the expected error, and leave the license output untouched. Both cases pass, including with the staged `wintypes` module.

## Sources and local changes

- [Xodus](https://github.com/xodus-gaming/xodus), commit `0670e25aeb0e0e9f800f8f2f4968ae3b681842a7`.
- [WineGDK](https://github.com/Sightem/WineGDK), commit `b5d23b074cfd5e28e79acceaaefaf41a26ce6272`.
- [macOS runtime reference](https://github.com/wtfsayo/cricket26-crossover): licensed Store integration and macOS IPC patches.
- CrossOver 26.3 official trial archive SHA-256: `8688e0848c4e5f79f1cc351cb52d32447da00c6c00cfd3b4bb2d164d44589a26`.
- Microsoft GDK `2604.4.7897` Gaming Services runtime provides the threading DLL. SHA-256: `aa611155057ebd01cf315ad702a4b5725aa9d5e6fad87732c956fe0a1e5fcfba`.

Apply the reference patches in `patches/` to their pinned source trees, then `minecraft-store-callback.patch` to WineGDK and `keychain-cache.patch` and `unified-helper.patch` to Xodus; use `patches/Cargo.lock`. The source clones, game, binaries, bottle, and private logs are ignored. `runtime/staged-hashes.json` records staged runtime hashes.

The credential-cache tests cover concurrent reads, persistent updates, failed writes, and deletion. Logs in `logs/` record the actual runtime and graphics checks. Store/account success alone does not establish multiplayer support.
