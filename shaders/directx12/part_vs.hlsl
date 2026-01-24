cbuffer PartVertexConstants : register(b0)
{
    float4x4 modelMatrix;
    float4x4 renderMatrix;
    float4 origin;
};

struct VSInput {
    float vertX   : POSITION0;
    float vertY   : POSITION1;
    float uvX     : TEXCOORD0;
    float uvY     : TEXCOORD1;
    float deformX : TEXCOORD2;
    float deformY : TEXCOORD3;
};

struct VSOutput {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

VSOutput vs_main(VSInput input) {
    VSOutput output;
    float2 offset = origin.xy;
    float2 deformed = float2(input.vertX - offset.x + input.deformX,
                             input.vertY - offset.y + input.deformY);
    float4 pos = float4(deformed, 0.0f, 1.0f);
    output.position = mul(renderMatrix, mul(modelMatrix, pos));
    output.uv = float2(input.uvX, input.uvY);
    return output;
}
