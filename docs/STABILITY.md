# Runtime stability and diagnostics

The September 30 stability branch is integrated with the native launcher.
The native app keeps its single account helper, progress reporting, cancellation,
structured errors, and one Keychain read per process. The additional fixes cover:

- Expired or incomplete Microsoft sign-in tokens are rejected. Device tokens are
  refreshed using the saved device identity; denied credential reads fail without
  replacing credentials.
- WineGDK renews Xbox tokens and forwards device authentication, obtains Xbox
  device/title tokens, and includes them in signed XSTS requests for friend joining.
- The launcher can remove a private, non-listening socket only when its recorded
  owner is dead. Unknown or active endpoints remain untouched.
- Completed downloads and prepared source trees are promoted without replacing
  a destination created concurrently. Existing full GDK downloads remain reusable;
  new component downloads retain the native launcher's verified 197 MB range path.
- Optional DXMT display-query and ColorSync lifetime fixes remain available as
  a separately built, verified Unix bridge.

## Graphics and packaging

Follow [the graphics notes](research/GRAPHICS.md) to build, probe,
and explicitly stage the optional bridge into an idle runtime. The default
[development build](DEVELOPMENT.md) still stages upstream DXMT. The memory fix
is not enabled merely by merging source or rebuilding the Swift interface.

When packaging a runtime with a bridge, the packager validates the original
libraries and source hashes, includes its patch/trace provenance, and records
new library hashes after ad-hoc signing. The launcher checks those packaged
bytes against the manifest. This preserves validation despite signature changes;
it does not establish a new graphics or gameplay test result.

## Gameplay evidence

The [gameplay history](history/GAMEPLAY.md#repeated-cross-platform-play) retains
the maintainer's 10+ cumulative hours with Xbox/PlayStation friends on an M4 Pro
Mac mini with 24 GB RAM, two monitored sessions and the M1 Air/16 GB working
report. Those reports do not establish a continuous soak, exact-candidate or
clean-machine acceptance. The earlier overnight freeze still needs retesting.

## Optional local monitoring and diagnostics

`Start.command` starts the local monitor for its game session. The native app
and `client/Launch Standalone.command` do not start it automatically. It does not upload
diagnostics:

```sh
python3 client/bedrock-monitor.py --help
python3 client/standalone.py launch --network-diagnostics
```

The second command launches the game and enables HTTP host/status diagnostics;
it is not an offline test. Do not start it alongside a running game/helper.
Use `client/Mark Problem.command` and `client/Stop Monitor.command` for an existing monitor
session. Raw captures stay private in `logs/standalone/monitor/` and are excluded
from source exports. Review excerpts before sharing them.

`Start.command` and `tools/start.py` provide the [source setup entry point](../README.md#start-from-source).
They reuse a completed installation, but do not update an installed game or
runtime. The separately packaged native app has its own data directory.

## Validation

Use [current testing instructions](TESTING.md) for a change. The
[October 5 integration record](history/GAMEPLAY.md#integration-validation-october-5-2026)
preserves the source/runtime evidence and limitations at that time. A later
source change or packaging pass needs its own record.
