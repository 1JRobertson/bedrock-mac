Capability-reporting code adapts BedrockOnLinux tools/dxr-probe.c, commit
7a315c836b7ae8068042bc466b0540c16ffe3a5e, MIT License (included alongside).
Upstream: https://github.com/Wyze3306/BedrockOnLinux
The isolated triangle shader/rendering path was added for this experiment.

Build and run through ../run.py, which applies the shared resource guard.
--capabilities-only is descriptive and its zero exit is not a rendering pass.
Only verdict.real_dxr_rendering: PASS establishes every GPU pixel matched the
CPU triangle oracle. The default mode tests DXR pipeline TraceRay; --inline tests inline RayQuery
and emits verdict.inline_ray_query_rendering: PASS. Neither independent mode
alone proves Minecraft rendering. It uses no Microsoft account, game assets or worlds.
