# Project context

Bedrock for Mac runs the owner's Windows Minecraft Bedrock installation on an
Apple Silicon Mac through WineGDK and DXMT. The intended user flow is **open the
app → Install & Play → Microsoft sign-in → Minecraft**, then **Play** on later
launches. A separate Minecraft welcome confirmation can still ask the user to
select **Sign in now**.

The repository is GPLv3 source with separately licensed upstream components.
It contains no Minecraft payload or Microsoft account. Current release status
and verified behavior live in [docs/RELEASE.md](docs/RELEASE.md). Original
CrossOver work is documented in [docs/LEGACY.md](docs/LEGACY.md).

## Components

| Component | Responsibility | Source of truth |
| --- | --- | --- |
| Native launcher | Window, Play/Cancel, status rendering, sign-out menu, worker lifetime | `launcher/BedrockLauncher.swift` |
| Worker | Installation checks, bundle wiring, setup lock, one account session, structured status | `launcher/setup.py` |
| Session runtime | Prefix preparation, account helper ownership, Wine environment, game launch | `standalone.py` |
| Account helper | Keychain cache, Microsoft login and license, game download, Xbox IPC | `standalone-helper.rs` and pinned Xodus patches |
| Acquisition tools | Helper compilation and verified Microsoft threading component | `standalone-setup.py` |
| GameInput preparation | Verify/extract known MSI files and prepare registry entries | `standalone-gameinput.py` |
| Windows compatibility | WineGDK with local GDK, Store, privilege, and Realms patches | `bootstrap-sources.py`, `patches/standalone-wine-*.patch` |
| Graphics | Pinned upstream DXMT and optional verified display-lifetime bridge | `build-standalone-graphics.sh` |
| Packaging | Swift bundle, frozen Python worker, runtime inventory, local DMG | `build-launcher.sh`, `package-launcher.py`, `build-dmg.py` |
| Source distribution | Explicit reviewed file allowlist and checksum inventory | `export-source.py`, `SOURCE-SHA256.txt` |

The [stability notes](docs/STABILITY.md) describe token renewal, device/title
authentication, recorded dead-socket recovery, and the optional graphics bridge.
The bridge's source provenance is included in packaged resources, with library
hashes recorded again after ad-hoc signing.

The account helper uses the real owner's Microsoft content license. The Store
callback compatibility patch does not fabricate ownership. DXMT handles
Direct3D 11; the launcher disables Direct3D 12 for the tested game path.

## Launch sequence

1. The native app runs the worker with `--status`, which reads existing state
   without signing in, downloading, or preparing a prefix.
2. Play starts the worker. It acquires `onboarding.lock`, copies current bundled
   scripts into the data directory, and points runtime/helper symlinks at the
   current app bundle. It checks hardware, OS, Rosetta, runtime, and free space.
3. For a new game, the worker starts one helper with `--download --serve-after`.
   For an existing game, it uses `--serve`. The helper checks the Microsoft
   session and ownership before exposing the Xbox service.
4. New or changed runtime setup acquires the verified threading DLL and prepares
   the separate Wine prefix, including GameInput. A setup signature makes
   unchanged preparation reusable.
5. `standalone.py launch` reuses the account service and runs
   `G:\\Minecraft.Windows.exe` in Wine. The outer worker keeps the helper alive.
6. Normal game exit returns the launcher to Play and stops the owned helper.
   Failure and cancellation unwind owned subprocesses; cancelled setup can be
   retried. Incomplete game downloads restart from scratch.

The app consumes newline-delimited JSON on worker stdout: `state`, `title`,
`detail`, and nullable `progress`. States include `new`, `ready`, `busy`,
`playing`, `cancelled`, and `error`; `checking` and `cancelling` are also used by
the front end. Only known progress lines and safe `BEDROCK_ERROR` codes are
translated into UI text. Arbitrary account output must not become UI text.

## Data and process ownership

| Item | Packaged app | Development checkout |
| --- | --- | --- |
| Root (`BEDROCK_HOME`) | `~/Library/Application Support/Bedrock for Mac` | Repository root by default |
| App components | App bundle `Contents/Resources` | `runtime/standalone/`, `sources/xodus/target/` |
| Game files | `<root>/game` | `<root>/game` or CLI `--game-dir` |
| Wine prefix and worlds | `<root>/bottles/Bedrock-Standalone` | Same relative path |
| Logs | `<root>/logs/standalone` | Same relative path |
| Runtime links and helper record | `<root>/runtime/standalone` | Same relative path |

The bundle's `BEDROCK_BUNDLE` tells the worker where to find shipped scripts and
components. The frozen worker also executes an allowlist of copied Python
scripts; players do not need a system Python or build tools. An app replacement
relinks its components at the next Play action. Game files and worlds live
outside the app, while credentials remain in Keychain.

The credential service is `Minecraft Bedrock Standalone`, item `account-v1`.
It holds the user and device token map. One process caches a single Keychain
read; direct writes avoid the old setter's extra reads. Sign-out removes the
user identity and user tokens, retaining the device identity and all game data.
Legacy token entries are left untouched rather than automatically imported.

`/tmp/xodus.sock` is a user-owned, mode-0600 Unix socket shared by the Xbox
integration. Only one helper can use it. The app checks the helper PID and
executable recorded in `runtime/standalone/helper-session.json` before reuse.
The helper also holds an account lock under
`~/Library/Application Support/Minecraft Bedrock Standalone/`. Setup, onboarding,
and standalone launch have their own lock files; the presence of a lock file
alone does not prove that a process still holds its lock.

Wine maps `G:` to the selected game and `R:` to the data root. The earlier
CrossOver prefix is `bottles/Bedrock-Mac`; it is not migrated automatically.

## Build and trust boundaries

Swift and the pinned DXMT target macOS 15, but the current local Wine/Python
bundle requires macOS 26. The packager scans native load commands and records
the highest minimum OS; a UI deployment target alone cannot establish support.
Wine and DXMT are x86-64 and require Rosetta; the native launcher is arm64.

Account and license traffic uses verified HTTPS. Game bytes use a separate
client without account headers/cookies; it currently permits the two catalog
HTTP CDN hosts documented in [STANDALONE-SETUP.md](STANDALONE-SETUP.md).
Some unencrypted package sections lack complete integrity authentication. This
is an unresolved release gate, not a claim that host allowlisting authenticates
HTTP downloads. See [SECURITY.md](SECURITY.md).

App resource checksums, a valid ad-hoc bundle signature, source checksums, and
notarization serve different purposes. None substitutes for game-package
authentication or clean-machine testing. Builds are currently ad-hoc signed;
rebuilding the helper can require new Keychain authorization.

## Where to make changes

- User journey or error copy: launcher files and [user guide](docs/USER_GUIDE.md).
- Account/download behavior: helper source plus source-level tests; preserve the
  one-helper lifecycle covered in `tests/test_onboarding.py`.
- Wine/Xodus fixes: tracked patches and bootstrap/build configuration, not just
  edits in ignored `sources/` or `build/` checkouts.
- New public files: explicit source-export allowlist and regenerated inventory.
- Build, packaging, or supported-version changes: [development guide](docs/DEVELOPMENT.md)
  and dated [release evidence](docs/RELEASE.md).
