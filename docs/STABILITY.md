# Stability fixes and earlier gameplay evidence

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

Follow [the graphics notes](../standalone-graphics-notes.md) to build, probe,
and explicitly stage the optional bridge into an idle runtime. The default
[development build](DEVELOPMENT.md) still stages upstream DXMT. The memory fix
is not enabled merely by merging source or rebuilding the Swift interface.

When packaging a runtime with a bridge, the packager validates the original
libraries and source hashes, includes its patch/trace provenance, and records
new library hashes after ad-hoc signing. The launcher checks those packaged
bytes against the manifest. This preserves validation despite signature changes;
it does not establish a new graphics or gameplay test result.

## Earlier gameplay results

These observations belong to the September 30, 2026 standalone development build
on an M4 Pro Mac mini with 24 GB RAM, macOS 15.3.1, WineGDK 11.8, DXMT v0.80,
and Minecraft 1.26.52. They do not establish the native package's minimum OS or
prove gameplay with the newly combined source.

| Scenario | Recorded result |
| --- | --- |
| Xbox multiplayer | User-confirmed cross-play; 1 hour 51 minutes monitored; normal exit |
| Xbox session memory | 4.18–5.15 GiB game footprint; normal system memory pressure throughout |
| PS5 friend world | User-confirmed entry after the device/title authentication fix, a retry, and a resource-pack download |
| PS5 session monitoring | 97 minutes; 3.39–5.10 GiB footprint; no detected crash, confirmed hang, or reported repeat join failure; subsequent normal exit |
| Local play | World rendering, saving, reopening, movement, fullscreen switching, and normal exit verified |
| Online services | Featured-server lobby entry and joined-Realm listing verified; active Realm entry untested |

An earlier overnight session froze after about nine hours with roughly 20 GB of
native small-object allocations. After the DXMT lifetime fixes, a five-minute
comparison measured about 0.36 MB of small-allocation growth versus 7.4 MB before.
The short comparisons and later multiplayer sessions do not prove overnight
stability. The transient Guardian error before successful PS5 entry was not
fully explained, and a disconnect/rejoin cycle remains unverified.

## Optional local monitoring and diagnostics

The monitor runs only when explicitly started; it does not upload diagnostics:

```sh
python3 bedrock-monitor.py --help
python3 standalone.py launch --network-diagnostics
```

The second command launches the game and enables HTTP host/status diagnostics;
it is not an offline test. Do not start it alongside a running game/helper.
Use `Mark Problem.command` and `Stop Monitor.command` for an existing monitor
session. Raw captures stay private in `logs/standalone/monitor/` and are excluded
from source exports. Review excerpts before sharing them.

`Start.command` and `start.py` retain the older source-building setup path for
development. They reuse a completed installation, but do not update an installed
game or runtime. The native app remains the documented player entry point.

## Integration validation, October 5, 2026

The combined source passed Python regression checks, Rust helper tests using
fixture credentials. A local native launcher build was blocked by duplicate
`SwiftBridging` module definitions in this Mac's Apple Command Line Tools; the
Swift sources are unchanged and the PR also requires the native CI build.
The merged Wine patches apply
in sequence and reproduce the existing runtime build source; that runtime passed
31 account-claim, 19 Realms-routing, and 18 token-refresh checks in a separate test
prefix. No existing game installation, saved world, or account was replaced.
A complete packaged build, fresh sign-in, gameplay, and overnight testing of the
combined version remain separate validation work.
