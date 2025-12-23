cbuffer MaskVertexConstants : register(b0)
{
    float4x4 mvp;
    float4 origin;
};

struct VSInput {
    float vertX   : POSITION0;
    float vertY   : POSITION1;
    float deformX : TEXCOORD2;
    float deformY : TEXCOORD3;
};

struct VSOutput {
    float4 position : SV_POSITION;
};

VSOutput vs_main(VSInput input) {
    VSOutput output;
    float2 offset = origin.xy;
    float2 deformed = float2(input.vertX - offset.x + input.deformX,
                             input.vertY - offset.y + input.deformY);
    output.position = mul(mvp, float4(deformed, 0.0f, 1.0f));
    return output;
}
