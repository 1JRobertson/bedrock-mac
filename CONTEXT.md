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
| Native launcher | Window, Play/Cancel, update and recovery actions, sign-out menu, worker lifetime | `launcher/BedrockLauncher.swift` |
| Worker | Installation checks, bundle wiring, setup lock, one account session, journaled updates, structured status | `launcher/setup.py` |
| Session runtime | Prefix preparation, account helper ownership, Wine environment, game launch | `standalone.py` |
| Account helper | Keychain cache, Microsoft login and license, game download, Xbox IPC | `standalone-helper.rs` and pinned Xodus patches |
| Acquisition tools | Helper compilation and verified Microsoft threading component | `standalone-setup.py` |
| GameInput preparation | Verify/extract known MSI files and prepare registry entries | `standalone-gameinput.py` |
| Windows compatibility | WineGDK with local GDK, Store, privilege, and Realms patches | `bootstrap-sources.py`, `patches/standalone-wine-*.patch` |
| Graphics | Pinned upstream DXMT and optional verified display-lifetime bridge | `build-standalone-graphics.sh` |
| Packaging | Swift bundle, frozen Python worker, runtime inventory, local DMG | `build-launcher.sh`, `package-launcher.py`, `build-dmg.py` |
| Release runtime reconstruction | Pinned source snapshot, native dependency receipts, isolated runtime build and validation | `build-release-runtime.py`, `release-runtime-profile.json`, `build-native-dependencies.py` |
| Source distribution | Explicit reviewed file allowlist and checksum inventory | `export-source.py`, `SOURCE-SHA256.txt` |

The [stability notes](docs/STABILITY.md) describe token renewal, device/title
authentication, recorded dead-socket recovery, and the optional graphics bridge.
The bridge's source provenance is included in packaged resources, with library
hashes recorded again after ad-hoc signing.

Optional source-development performance profiles are recorded in
[the graphics notes](standalone-graphics-notes.md). Their builders cover shared
buffers, packed constants, input-layout reuse, Wine heap reuse, and an exact-game
allocator experiment. Launch-time allocator and frame-pacing gates require local
staging records and matching runtime hashes; a normal unstaged installation does
not enable them. The October 6 metrics HUD remains disabled after a startup crash
and rollback. These local observations do not establish packaged-app validation.

The newer constant-buffer borrowing and exact-current allocator candidates have
separate build-only commands. They do not stage a runtime or change launch
defaults. The allocator builder composes pinned Wine heap/refmove patches and
checks the exact game build before installing its in-process hook. Differential
tests extract reference instructions only from the owner's hash-verified local
game into ignored build output; the source export contains no game functions.

The separate frame-slab candidate extracts allocation policy into a C core with
memory and locking callbacks. Its exact-build adapter admits only verified frame
workers and retains storage through the native frame cleanup boundary. Its
builder remains build-only and default-off. A separate
`standalone-bedrock-frame-profile.py` installer accepts only the frozen tested
DLL, verifies the heap/refmove baseline, journals replacements, and preserves
exact rollback files. The regular source launcher verifies the installed record
before enabling 16 KiB slabs and creates a private control map per game session.
Unstaged installations remain unchanged. The control tool changes chunk sizes
for future frames; live status reads atomic lifecycle gauges, while per-thread
counters are decoded only after exit.

The standalone native-batch experiment under `tests/` measures a Rosetta client
and ARM64 companion using shared memory and semaphores. It has no game hook or
runtime integration. Its synthetic visibility workload tests communication
cost and coarse batch feasibility; it is not evidence of improved game FPS.
An additional experimental clone-recurrence overlay preserves the original
constructors and records bounded byte-repetition counts. Its numeric mapping
uses coherent per-thread snapshots. It is default-off and has passed synthetic
Windows tests plus a bounded October 7 capture in the isolated copied world.
The dominant observed path repeatedly copied equal payloads and metadata;
this does not establish safe sharing or a gameplay performance improvement.
A separate binding-recurrence overlay
measures the three binding-copy paths with shared per-thread history; its own
DLL passed private synthetic runtime tests and a bounded October 7 copied-world
capture: 145,881 of 147,456 observed copies matched recent contents at one site.
The other two sites did not run; recurrence does not establish safe aliasing.
After desktop control recovered, a foreground OFF/16/OFF/16/OFF frame-slab
comparison showed 18–21% lower aggregate CPU per displayed frame, with
essentially unchanged FPS. OFF includes instrumentation overhead. Separate
normal-module captures observed 13–27% less CPU/frame with the pure slab candidate, but cross-launch variation
prevents a precise causal percentage. Neither comparison demonstrated an FPS
gain. On October 7 the frozen pure slab profile was enabled in this machine's
regular source-development runtime after copied-world terrain/save/reload tests
and exact install/rollback checks. The regular `Launch Standalone.command` path
then passed the live 16-site startup guard. Recurrence observers and the
exact-current rewrite remain disabled. This is local qualification, not packaged
app or broad hardware validation; evidence is in the graphics notes.

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

**Update Minecraft…** stages the download separately, preserves the previous
game and Wine prefix, and journals activation. Standalone launch refuses to run
while an update journal is pending. Recovery retains displaced data under
`game-backups` rather than deleting potentially newer worlds. **Open Game Data**
opens the data folder for recovery. Synthetic interruption tests exercise these
paths; an actual packaged game upgrade remains a release gate.

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

Newly started helpers receive the owning process ID and a private session
receipt path. Before authentication, the helper verifies that receipt; it then
exits if its parent disappears. The launcher publishes the receipt before
waiting for readiness. This bounds orphan-helper lifetime after a worker crash
without killing processes belonging to other sessions.

Wine maps `G:` to the selected game and `R:` to the data root. The earlier
CrossOver prefix is `bottles/Bedrock-Mac`; it is not migrated automatically.

## Build and trust boundaries

Swift and the pinned DXMT target macOS 15. The October 7 scan of the selected
Wine and Python inputs found deployment targets no higher than 15.0; the older
macOS 26 package claim does not describe these inputs. Each assembled app still
requires a complete native load-command audit. The packager records that audit
in `native-minimums.json` and sets the app's highest required minimum OS; a UI
deployment target alone cannot establish support. Wine and DXMT are x86-64 and
require Rosetta; the native launcher is arm64.

The release-runtime driver exports a verified source snapshot into a new
workspace and requires a checksummed, source-built native dependency prefix.
It separates build, graphics validation, and gameplay evidence. The October 7
source reconstruction completed, and the exact rebuilt graphics bridge passed
presentation, pixel-readback, texture, and discard probes before staging. RC3
packages that rebuilt runtime and passed those probes again from the actual
app in a disposable prefix. Gameplay and replacement-dependency behavior in
Minecraft remain untested.

Account and license traffic uses verified HTTPS. RC2 and RC3 carry a helper
that rewrites legacy game-package URLs to `dlassets-ssl.xboxlive.com`; the real
RC2 acquisition returned HTTP 404 on all four requests. That route has not
produced a working fresh installation.

A replacement acquisition path in `standalone-helper.rs` and
`standalone-xvd.rs` passed a full owned-game acquisition on October 7. It permits catalog-selected public package bytes
from the two Microsoft HTTP origins only into private quarantine, with no
account headers, cookies, URL credentials, query strings, or redirects. A pinned
production public key authenticates the fixed header before layout parsing;
the selected catalog identity and size bind the package. Full hash-tree and
payload-page verification completes before the existing parser or
extraction uses it. An authenticated reader excludes unsigned regions and
checks subsequent reads from that same local package. The tested helper
verified all 2,975 hash-tree pages and 502,386 data pages, then extracted and
prepared 12,179 files using the owner's license. Catalog content IDs and
versions must agree before the signed header can trigger licensing or bulk
transfer. Independent review and rejection/cancellation fixtures passed.
RC4 (0.3.0 build 6) packages this exact helper. A prior October 7 working note
reports a native first-run retry reaching game-process launch and same-session
close/reopen/quit checks. An artifact-bound acceptance receipt for that session
is not included in the source record, so those observations do not close the
native first-run gate in [release readiness](docs/RELEASE.md). Human RC4
gameplay/save-reopen, clean-M1 installation, multiplayer, measured soak and real
update/recovery remain unverified. RC3 retains the older download route.
Account TLS and Microsoft ownership checks remain in force.
See [SECURITY.md](SECURITY.md).

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
