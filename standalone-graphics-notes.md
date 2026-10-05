# Standalone graphics

These are component notes and historical test observations. The current complete
app's minimum OS and verified behavior are in [release status](docs/RELEASE.md);
the component's deployment target does not establish support for the whole app.

`build-standalone-graphics.sh` stages the upstream DXMT v0.80 release into
`runtime/standalone/dxmt/`. It checks the pinned SHA-256 before extracting only
the four x64 graphics DLLs and `winemetal.so`. No CrossOver payload is used.
The installer does not change a Wine prefix or game files.

The release is MIT licensed and targets **macOS 15.0 or newer**, despite the
source build documentation's broader Sonoma requirement. It contains an x86_64
Unix library, so Apple Silicon requires Rosetta. Upstream source compilation
requires LLVM 15 and Xcode 16's Metal tools; the verified release avoids installing
that toolchain. Its release and source provenance are recorded in `manifest.json`.

After building standalone Wine:

```sh
./build-standalone-graphics.sh --wine-runtime "$PWD/runtime/standalone/wine"
./build-standalone-probes.sh
```

The first command installs the five DXMT binaries into our standalone Wine's
`lib/wine/` tree, backing up displaced Wine binaries under DXMT's `wine-originals/`.
This is necessary because installed Wine 11.8 searches its own DLL directory
before `WINEDLLPATH`. Re-run this command after reinstalling Wine. It also links
our Wine's `ntdll.so` and `winemac.so` into DXMT's separate staging directory.
DXMT's upstream `@rpath` entries resolve these relative to `winemetal.so`.
The Windows DLLs retain their Wine builtin markers. The launcher can retain the
DXMT directory itself in `WINEDLLPATH` and must use:

```text
d3d11,dxgi,d3d10core,winemetal=b
```

DXMT v0.80 supports Direct3D 10/11, not Direct3D 12. The standalone launcher
disables Direct3D 12 with `d3d12,d3d12core=`. Minecraft 1.26.5203.0 successfully
falls back to Direct3D 11, reports feature level 11.1, and reaches gameplay.
The user confirmed it working on September 29, 2026. This was tested in the
separate standalone prefix; the earlier CrossOver bottle remains intact.

DXMT v0.80 expects a legacy Wine macOS window-data layout. Standalone Wine uses
`patches/standalone-wine-dxmt-abi.patch` to export an adapter table with that layout,
keeping Wine's own internal layout unchanged. Merely creating a D3D11 device
does not exercise this window bridge.

`runtime/standalone/probes/standalone-graphics-probe.exe` creates a hidden window,
requests a hardware FL11.0 device and swapchain, clears a GPU texture red, reads
it back, and presents. Success requires `RedPixel=0xFF0000FF` and successful HRESULTs
(an occluded presentation status is acceptable). It has a 45-second watchdog and
does not show a game window. This probe checks the basic GPU/window bridge;
it does not cover every shader or gameplay scenario.

The same probe builder produces the existing account and Store-callback probes.
It copies only the owner's `MicrosoftGame.Config` beside these probes, as required
by GDK, and leaves the original game directory unchanged. All generated output
stays under ignored `runtime/`.

On 2026-09-29, the standalone Wine 11.8 + upstream DXMT v0.80 package passed both
device creation and the hidden-window probe on this M4 Pro / macOS 15.3.1.
The swapchain, GPU readback, and presentation returned `S_OK`; the red pixel
matched `0xFF0000FF`. Evidence is in `build/dxmt/swapchain-probe-dxmt.log`.
An initial `E_FAIL` came from Wine's own D3D11 DLL shadowing DXMT, resolved by the
installation overlay above. The subsequent Minecraft test confirmed the D3D11
fallback and working gameplay. Inspection of the live game process found the
standalone Wine and DXMT Metal library loaded, with no CrossOver or D3DMetal
files mapped. A later test entered the Lifeboat online lobby with other players.
PS5 friend sessions, active Realm gameplay, save reopening, and broader gameplay
coverage remain untested.
