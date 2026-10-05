# Testing and validation

Run checks from the repository root. Prefer tests that reproduce a failure at
its real boundary; avoid tests that only restate implementation. Documentation
changes need link, command, export, and checksum checks, not a fresh game install.
Test counts below describe the October 5, 2026 source snapshot.

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
python3 export-source.py --check
shasum -a 256 -c SOURCE-SHA256.txt
git diff --check
```

The Python suite currently has 77 tests. Coverage includes source isolation,
one helper across download/preparation/launch, safe account error messages,
process cancellation, setup-marker corruption, runtime relinking, reduced
download verification, and packaged minimum OS detection. The count is a dated
snapshot, not a requirement to keep it fixed.

After fetching upstream sources, verify their pinned patched state:

```sh
python3 bootstrap-sources.py --check
```

That check is offline; the initial `bootstrap-sources.py` fetch is not. If an
exported source file changed, first regenerate `SOURCE-SHA256.txt` following
[PUBLISHING.md](PUBLISHING.md#update-the-source-inventory).

## Native app and helper

Compile the interface on a Mac with Command Line Tools:

```sh
./build-launcher.sh
```

Use local fixture status streams to inspect first-run, progress, cancellation,
retry, error, and running-game states without touching a real account. Keep
fixtures in ignored build output. A fixture proves UI behavior only. The worker
protocol and ownership model are in [CONTEXT.md](../CONTEXT.md).

Prepare the current standalone helper example and run its tests after quitting
Minecraft and letting its helper stop. The builder rejects any active
`standalone_helper`, including one in a packaged app:

```sh
python3 standalone-setup.py --build-helper
cargo +1.98.0 test --release --locked --manifest-path sources/xodus/Cargo.toml \
  -p xodus-cli --example standalone_helper
```

There are currently 12 default helper tests and two ignored live fixtures.
Default tests use fake/in-memory token storage and check cache reads, denied
reads, failed writes, sign-out, package paths, and URL policy. Do not add
`--include-ignored` to routine tests: the ignored Keychain fixture creates its
own random entry, and the ignored CDN fixture makes a live request. Neither
proves the prompt behavior of a user's saved account.

## Wine and graphics

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
./build-standalone-probes.sh
python3 standalone.py probe graphics
```

Expected graphics evidence includes successful HRESULTs and
`RedPixel=0xFF0000FF`. Account, Store, and privilege probes can prompt and contact
Microsoft. Never run those under the assumption that all probes are offline.

## Verify a packaged artifact

`package-launcher.py` verifies the final bundle signature and records hashes of
regular resource files in `Contents/Resources/payload-sha256.json`.
`build-dmg.py` verifies the DMG. To check an existing default artifact:

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
