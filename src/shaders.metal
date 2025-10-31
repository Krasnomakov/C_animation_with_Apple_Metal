#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]], constant float &time [[buffer(1)]]) {
    float angle = time;
    float s = sin(angle);
    float c = cos(angle);

    float2 positions[3] = { {0.0,  0.6}, {-0.55, -0.3}, {0.55, -0.3} };
    float3 colors[3] = { {1,0,0}, {0,1,0}, {0,0,1} };

    float2 p = positions[vertexID];
    float2 rot = float2(p.x * c - p.y * s, p.x * s + p.y * c);

    VertexOut out;
    out.position = float4(rot.x, rot.y, 0.0, 1.0);
    out.color = colors[vertexID];
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
