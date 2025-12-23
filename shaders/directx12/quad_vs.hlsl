cbuffer QuadVertexConstants : register(b0)
{
    float4x4 transform;
    float4 uvRect; // xy = min uv, zw = max uv
};

struct VSOutput {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

static const float2 basePositions[6] = {
    float2(-0.5f, -0.5f),
    float2(-0.5f,  0.5f),
    float2( 0.5f, -0.5f),
    float2( 0.5f, -0.5f),
    float2(-0.5f,  0.5f),
    float2( 0.5f,  0.5f)
};

static const float2 baseUvs[6] = {
    float2(0.0f, 0.0f),
    float2(0.0f, 1.0f),
    float2(1.0f, 0.0f),
    float2(1.0f, 0.0f),
    float2(0.0f, 1.0f),
    float2(1.0f, 1.0f)
};

VSOutput vs_main(uint vertexId : SV_VertexID) {
    VSOutput output;
    float2 pos = basePositions[vertexId];
    output.position = mul(transform, float4(pos, 0.0f, 1.0f));
    float2 uvMin = uvRect.xy;
    float2 uvMax = uvRect.zw;
    output.uv = lerp(uvMin, uvMax, baseUvs[vertexId]);
    return output;
}
