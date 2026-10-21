// A fixed triangle, with actual TraceRay traversal. Distinct hit/miss colors
// make GPU readback an objective test rather than a capability-bit check.
RaytracingAccelerationStructure scene : register(t0);
RWStructuredBuffer<uint> pixels : register(u0);
struct Payload { uint color; };

[shader("raygeneration")]
void RayGen()
{
    uint2 xy = DispatchRaysIndex().xy;
    float2 p = (float2(xy) + 0.5) / float2(DispatchRaysDimensions().xy) * 2 - 1;
    RayDesc ray;
    ray.Origin = float3(p.x, -p.y, -1);
    ray.Direction = float3(0, 0, 1);
    ray.TMin = 0.001;
    ray.TMax = 10;
    Payload payload;
    payload.color = 0x00ff00ff; // unexpected magenta if neither shader executes
    TraceRay(scene, RAY_FLAG_NONE, 0xff, 0, 1, 0, ray, payload);
    pixels[xy.y * DispatchRaysDimensions().x + xy.x] = payload.color;
}

[shader("miss")]
void Miss(inout Payload payload) { payload.color = 0x00302010; }

[shader("closesthit")]
void ClosestHit(inout Payload payload, BuiltInTriangleIntersectionAttributes a)
{ payload.color = 0x0020e040; }
