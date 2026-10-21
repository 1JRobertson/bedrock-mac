# Native compatibility sources

| Directory | Purpose |
| --- | --- |
| `file-pickers/` | Source-built Windows picker bridge and independent ABI contracts |
| `graphics/` | DXMT display/ColorSync lifetime tracing source |
| `probes/` | Native/Windows component probes used by reviewed builders |

This directory contains source, not an installed runtime. Build tools are under
`tools/`; runtime outputs remain under ignored root `build/` and `runtime/`.
The [picker guide](file-pickers/README.md) describes its API boundary and checks.
[Graphics notes](../docs/research/GRAPHICS.md) retain component validation.
Native probes can prepare prefixes or access an account: select them deliberately
using [the testing guide](../docs/TESTING.md#wine-and-graphics).
