Process-local Metal 3.2 fallback experiment

Problem: Mullion v0.3 embeds an internal mullion_command metallib compiled with
Metal language 4.1. macOS 15.3.1 refuses it before D3D12 device construction.
The source's Meson internal shader command does not specify -std; this differs
from airconv shaders compiled explicitly for 3.1.

build.sh uses the existing CLT clang, not the unavailable offline metal tool.
Run it through the shared QA resource guard, then test through the same guard.

Inject into only the isolated Wine process by ADDING these after run.py's
normal environment() sanitation:
 DYLD_INSERT_LIBRARIES=/absolute/experiment/compat/metal32_fallback.dylib
 MULLION_COMPAT_INTERNAL_SOURCE=/absolute/experiment/compat/command-inlined.metal

This dylib swizzles the selected device's newLibraryWithData:error: implementation.
It first calls the real method. Only if it fails with a language-version-4.1 error,
and its data contains BOTH Mullion internal function names, it compiles the pinned
inlined internal source with languageVersion 3.2. All other libraries/results use
the original method. It changes no Metal, working Wine, or production client files.

The recorded native run passed both pipeline and inline GPU readback tests;
see ../RESULTS.md for the actual tested environment and limitations. If runtime source
compilation fails, its exact shader diagnostic is printed. If it succeeds, re-run
the actual ray-readback probe; compilation does not establish rendering correctness.
Include dylib and inlined source SHA-256 in any pass fingerprint.
