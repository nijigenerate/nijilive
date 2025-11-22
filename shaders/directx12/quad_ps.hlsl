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

struct PSOutput {
    float4 albedo : SV_Target0;
    float4 emissive : SV_Target1;
    float4 bump : SV_Target2;
};

float3 screenBlend(float3 baseColor, float alpha, float3 screenTint) {
    return 1.0f - ((1.0f - baseColor) * (1.0f - (screenTint * alpha)));
}

PSOutput ps_main(PSInput input) {
    PSOutput output;
    float4 base = albedoTexture.Sample(linearSampler, input.uv);
    float opacity = tintColor.w;
    float3 mult = tintColor.xyz;
    float3 screenTint = screenColor.xyz;

    float3 albedoColor = screenBlend(base.xyz, base.w, screenTint) * mult;
    output.albedo = float4(albedoColor, base.w) * opacity;
    output.emissive = emissiveTexture.Sample(linearSampler, input.uv);
    output.bump = bumpTexture.Sample(linearSampler, input.uv);
    return output;
}
