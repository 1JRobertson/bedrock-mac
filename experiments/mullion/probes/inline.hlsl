// DXR 1.1 / Shader Model 6.5 inline traversal. Compile -T cs_6_5 -E main.
// Uses the same BLAS/TLAS, rays, colors and CPU oracle as triangle.hlsl.
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<uint> pixels : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 thread : SV_DispatchThreadID)
{
    uint2 xy = thread.xy;
    if (any(xy >= 64)) return;
    float2 p = (float2(xy) + 0.5) / 64.0 * 2 - 1;
    RayDesc ray;
    ray.Origin = float3(p.x, -p.y, -1);
    ray.Direction = float3(0, 0, 1);
    ray.TMin = 0.001;
    ray.TMax = 10;
    RayQuery<RAY_FLAG_FORCE_OPAQUE> query;
    query.TraceRayInline(scene, RAY_FLAG_NONE, 0xff, ray);
    while (query.Proceed()) { }
    pixels[xy.y * 64 + xy.x] = query.CommittedStatus() == COMMITTED_TRIANGLE_HIT
        ? 0x0020e040 : 0x00302010;
}
