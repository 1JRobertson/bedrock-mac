# Testing and validation

Run checks from the repository root. Prefer tests that reproduce a failure at
its real boundary; avoid tests that only restate implementation. Documentation
changes need link, command, export, and checksum checks, not a fresh game install.
Test counts below are dated snapshots, not the current suite's required count.

## Choose the relevant checks

| Change | Validation |
| --- | --- |
| Worker/session behavior | Python suite; targeted cancellation/helper-lifetime regression; local app check when UI behavior changes |
| Helper/account/download behavior | Python orchestration suite and Rust helper tests; deliberate live check only when required |
| Swift launcher | Native build plus visible local checks for affected states |
| Wine account/Realms patches | Pinned-source checks, rebuilt runtime, XUser tests, and relevant probe/game test |
| Graphics/runtime assembly | Build and overlay verification, graphics probe, game launch on the target Mac |
| Packaging | Python packaging tests, signature/resource/DMG verification, Applications launch with existing data |
| Documentation/export list | Relative links and examples, source-export tests/check, regenerated source inventory |

## Offline source checks

These checks do not use the user's account, Keychain, or game data:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tools/export-source.py --check
shasum -a 256 -c SOURCE-SHA256.txt
git diff --check
```

After fetching upstream sources, verify their pinned patched state:

```sh
python3 tools/bootstrap-sources.py --check
```

That check is offline; the initial `tools/bootstrap-sources.py` fetch is not. If an
exported source file changed, first regenerate `SOURCE-SHA256.txt` following
[PUBLISHING.md](PUBLISHING.md#update-the-source-inventory).

Record the current command, revision, result and skips in the PR. The
[October 21 source audit](history/AUDIT-2026-10-21.md) is a dated example, not a
required fixed test count.

## Experimental checks

Performance experiments are separate from the supported startup path. Their
build/probe commands and measurement limits are indexed in
[research](research/README.md). Dated source, frame-slab, graphics and skin results
are retained in [test history](history/TESTING.md); they do not certify a new app.

## Source layout and packaged scripts

`python3 -m unittest discover -s tests -p 'test_repository_layout.py'` exports
only reviewed source and exercises the supported CLI entry points from an
unrelated working directory. It checks that read-only startup preserves a fake
existing app-data root and that the pinned release plan creates no workspace.
Packaging/picker fixtures separately verify flat shipped script names and strict
acceptance of existing runtime receipts through retained build provenance.

`test_start.py` exercises setup-cache writes against stale symlinks/hardlinks and
simulated write/publication failures, preserving previous receipts and unrelated
files. Source-build path regressions in it and `test_standalone_setup.py` reject
unsupported paths before build tools, downloads or build output are created.
These isolated fixtures do not rebuild Wine or qualify gameplay.

## Native app and helper

Compile the interface on a Mac with Command Line Tools:

```sh
./tools/build-launcher.sh
```

Use local fixture status streams to inspect first-run, progress, cancellation,
retry, error, and running-game states without touching a real account. Keep
fixtures in ignored build output. A fixture proves UI behavior only. The worker
protocol and ownership model are in [CONTEXT.md](../CONTEXT.md).

The portable lifecycle regression requires Apple Silicon, macOS 15+ and Command
Line Tools. Choose a new output directory:

```sh
python3 tests/check-launcher-lifecycle.py --output build/launcher-lifecycle-check
```

It exercises the production controller/delegate with a dummy local worker and
intercepted sheet presentation. It uses no real account, game or visible UI.
The recorded local run passed; actual SwiftUI red-close/reopen and sheet behavior
have separate native fixture evidence. Neither qualifies RC4 gameplay.

Prepare the current standalone helper example and run its tests after quitting
Minecraft and letting its helper stop. The builder rejects any active
`standalone_helper`, including one in a packaged app:

```sh
python3 client/standalone-setup.py --build-helper
cargo +1.98.0 test --release --locked --no-default-features \
  --manifest-path sources/xodus/Cargo.toml -p xodus-cli --example standalone_helper
```

Use `--no-default-features` to match the minimal shipping helper. Bootstrap
copies all three helper inputs: the example, XVD verifier module and pinned
public key; no separate manual copy is needed.

Default tests use fake/in-memory credentials. Coverage includes credential
cache and denial handling, sign-out, paths/URL policy, signature rejection,
hash-tree corruption and identity checks, and verified local-reader bounds,
reopen and changed-backing-file rejection. Test counts change with the source;
record the actual command, source hashes and result for each run.

Do not use `--include-ignored` routinely. Select opt-in fixtures individually:
the parent-death child needs its isolated controller; the Keychain fixture uses
only its own random entry; the live CDN fixture requests a two-byte endpoint;
owned-package and cached-header/metadata fixtures require the documented
`XVD_TEST_*` inputs. Cached/header-only checks and the CDN probe do not prove
complete package acquisition. Real account sign-in is a separate, explicit
live test with the user handling credentials and security prompts.

## File picker compatibility

The Wine builder includes the source-built PNG/world picker bridge. Prefix setup
checks its source receipt, preserves previous DLL/registry evidence, and refuses
to replace an unknown provider. Its installation fixtures run in the Python
suite; Windows CI independently compiles the DLL and runs the mocked-dialog ABI
contracts against the Windows SDK. Neither needs Minecraft or an account.

These checks do not prove that Minecraft imports a skin. Native acceptance must
open and cancel **Dressing Room → Choose New Skin**, select a valid PNG, handle an
invalid image, restart to check persistence, and regress world import/export.
Use an isolated prefix and disposable worlds; retain the existing installation.
See [bridge build and ABI notes](../native/file-pickers/README.md).

The [October 19 native checks](history/TESTING.md#october-19-native-skin-check)
and [October 20 persistence diagnosis](history/TESTING.md#october-20-skin-persistence-diagnosis)
record the exact tested source, game and limits. Issue #4 stays open for reporter
verification; a newer game's restart behavior and world import/export need tests.

## Wine and graphics

The opt-in allocator source has an additional local differential check:

```sh
python3 tests/run-bedrock-exact-differential.py \
  --game /absolute/path/to/owned/Minecraft.Windows.exe \
  --output build/allocator-differential
```

It accepts only the exact reviewed executable digest and extracts reference
instructions into ignored output. It does not modify or launch the game.
The regular Python suite tests the synthetic allocator and build boundaries
without requiring a game. Building a candidate, passing these tests and measuring
game performance remain separate checks; see the
[render-allocation notes](research/ALLOCATORS.md#october-6-render-allocation-candidates).

After building standalone Wine, run:

```sh
bash tests/run-xuser-tests.sh
```

This compiles against the actual patched headers and runs 31 claim checks and
19 Realms-routing and 18 token-refresh checks using synthetic data. It uses the separate
`runtime/standalone-wine-prefix` and writes `build/standalone-wine/xuser-*-test.log`.
It does not access Microsoft. See [tests/XUSER.md](../tests/XUSER.md).

The graphics probe requires the owned game/runtime prerequisites and prepares
the standalone game prefix; it is not a pure source test:

```sh
./tools/build-standalone-probes.sh
python3 client/standalone.py probe graphics
```

Expected graphics evidence includes successful HRESULTs and
`RedPixel=0xFF0000FF`. Account, Store, and privilege probes can prompt and contact
Microsoft. Never run those under the assumption that all probes are offline.

## Verify a packaged artifact

`tools/package-launcher.py` verifies the final bundle signature and records hashes of
regular resource files in `Contents/Resources/payload-sha256.json`.
`tools/build-dmg.py` verifies the DMG. To check an existing default artifact:

```sh
codesign --verify --deep --strict 'build/packaged/Bedrock for Mac.app'
hdiutil verify 'build/Bedrock for Mac.dmg'
shasum -a 256 'build/Bedrock for Mac.dmg'
python3 - <<'PY'
from pathlib import Path
import hashlib, json, plistlib
app = Path('build/packaged/Bedrock for Mac.app')
resources = app / 'Contents/Resources'
inventory = json.loads((resources / 'payload-sha256.json').read_text())
for name, expected in inventory.items():
    actual = hashlib.sha256((resources / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit('Resource differs: ' + name)
with (app / 'Contents/Info.plist').open('rb') as file:
    print('Minimum macOS:', plistlib.load(file)['LSMinimumSystemVersion'])
print('Verified resource files:', len(inventory))
PY
```

Adjust paths for a separately named build. These checks detect changes relative
to the recorded artifact; they do not authenticate game downloads or establish
notarization. Opening an app assembled on the developer's Mac does not reproduce
Gatekeeper's handling of a downloaded app on another Mac.

## Manual test record

Use a separate macOS account or test Mac for clean-state tests; do not erase the
owner's worlds or Keychain to simulate a new user. The person testing enters
their own credentials and handles security prompts. Record one row per scenario
with date, app commit/artifact checksum, macOS/chip, game version, initial data
state, action, observed result, and any reviewed diagnostic excerpt.

| Scenario | Expected result |
| --- | --- |
| DMG → Applications | App opens from Applications; all runtime components come from that bundle |
| Missing Rosetta or unsupported OS | Clear prerequisite message before account setup |
| Fresh owner sign-in | One helper owns sign-in, download, setup, and play; correct gamertag is confirmed in game |
| Cancel, close sign-in, deny Keychain, interrupt network | Actionable state, owned processes cleaned up, safe retry, existing data preserved |
| Repeat launch, unchanged helper | After the tester chooses Always Allow, measure whether saved access is remembered; record the exact number of prompts |
| Quit/reopen launcher window | Session remains alive while Minecraft runs; window can be reopened |
| Quit/relaunch game | Returns to Play and launches successfully again |
| Save and reopen a world | A disposable test world survives normal quit and relaunch |
| Sign out and switch owner account | Game/worlds retained; new account ownership checked; no old user session restored |
| App replacement | Existing game/worlds retained; new bundle links used; prompt count recorded rather than assumed |
| Multiplayer | Separately record server entry, Realm listing, active Realm entry, and friend-session joining |

These are acceptance criteria, not claims that each row has passed. Put observed
results in [RELEASE.md](RELEASE.md), including failures and untested cases.

## Continuous integration

[`.github/workflows/checks.yml`](../.github/workflows/checks.yml) runs Python
3.12/3.14 source tests, allowlist and inventory checks on Linux, plus the Python suite, native
Swift build, and pinned Rust helper tests on macOS 15. Native process metrics
and exclusive-rename tests run on macOS and are skipped on Linux. Actions and the Rust
toolchain are pinned. CI does not package Wine, run Minecraft, access Keychain,
or certify that the full app supports macOS 15. Confirm checks belong to the
exact PR commit before merging.
