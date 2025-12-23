cbuffer PartPixelConstants0 : register(b0, space1)
{
    float4 tintColor;
    float4 screenColor;
    float4 extraParams;
};

Texture2D albedoTexture : register(t3);
Texture2D emissiveTexture : register(t4);
Texture2D bumpTexture : register(t5);
SamplerState linearSampler : register(s0);

struct PSInput {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD0;
};

float4 ps_main(PSInput input) : SV_TARGET {
    float4 baseColor = albedoTexture.Sample(linearSampler, input.uv);
    const float maskThreshold = extraParams.x;
    const bool isMask = (extraParams.z > 0.5f);

    if (isMask) {
        if (baseColor.a <= maskThreshold) discard;
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float4 tinted = baseColor * tintColor;
    tinted.rgb += screenColor.rgb * baseColor.a;
    return tinted;
}
