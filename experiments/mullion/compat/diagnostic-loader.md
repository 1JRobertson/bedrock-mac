# Diagnostic D3D12 loader

`build-loader.sh` builds `../out/diagnostic-loader/d3d12.dll` using the existing
Wine build tools. It changes no prefix or installed runtime. Run the build and
any native testing through the repository QA resource guard.

The eight original Mullion loader exports forward to this prefix's system32
`d3d12core.dll`. Only an explicit
`MULLION_DIAGNOSTIC_RETRY_FL12_0=1` enables one diagnostic exception:
a `D3D12CreateDevice` call requesting minimum feature level 12_0 that returns
`E_INVALIDARG` is retried with minimum 11_0. The 12_1 request is untouched.
A notice is written on every retry. All feature queries and device interfaces
are the original core implementation; no tier or capability field is changed.

For isolated staging, preserve the experiment's original `d3d12.dll`, install
this DLL into only its system32, and set its Wine override to `d3d12=n` while
leaving `d3d12core=b`. Set the opt-in environment variable after the launcher
sanitizes inherited `MULLION_*` values. Restore the original loader and override
after the diagnostic. Add the wrapper hash and opt-in value to evidence manifests.

This deliberately weakens the requested minimum contract. It does not make the
device feature-level-12 compatible. An application requiring tiled/sparse
resources may fail later. `E_INVALIDARG` alone cannot prove which input caused
the original failure; the retry must be interpreted with the observed core log.
It is suitable only for exposing subsequent isolated compatibility failures.
Do not treat loader success, a graphics menu toggle, or a framebuffer as proof
of Minecraft ray tracing. Require real DXR traversal/readback and in-world evidence.

C implementation and spec were checked with the existing Windows-target clang.
The exports' ordinals and argument declarations match Wine's d3d12.spec and
Mullion's eight-function loader. Native execution is a separate parent-run check.

## Limited aggregate profile added after crash diagnosis

`--relaxed-level` separately enables `MULLION_DIAGNOSTIC_RELAX_LEVELS=1`.
Unlike retry-only mode, it changes FEATURE_LEVELS' aggregate maximum to12_0;
individual OPTIONS values, including actual sparse tier0, remain unchanged.
The profile requires ID3D12Device10 before touching extended vtable slots.
Installation is serialized and original methods are published before hooks.
This allows this Minecraft build to select D3D12 on macOS15.3.1, but it does not
establish complete FL12_0 conformance. Actual reserved-resource calls are traced
and forwarded to the original implementation, which may reject unsupported work.

The previous immediate crash was traced separately to a wrongly named GDK native
threading DLL in our experimental setup. The correctly named/pinned file is now
staged and checked by run.py. With that fix and this profile, both pipeline and
inline ray GPU readbacks pass and the game stays alive through D3D12 initialization.
Visual world/RT verification remains outstanding.

ray-trace.inc adds opt-in bounded CPU command-recording evidence. A nonzero
BuildAS/DispatchRays count is not GPU completion; zero counters cannot exclude
ExecuteIndirect or shaders whose inline names were stripped. The independent
ray probes add fenced GPU readback and exact CPU pixel comparison.
