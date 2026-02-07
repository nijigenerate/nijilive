Shader "Nijilive/UnlitURP"
{
    Properties
    {
        _BaseMap ("Base Map", 2D) = "white" {}
        _MaskTex ("Mask Tex", 2D) = "white" {}
        _ExtraTex ("Extra Tex", 2D) = "black" {}
        _BaseColor ("Base Color", Color) = (1,1,1,1)
        _ScreenTint ("Screen Tint", Color) = (0,0,0,0)
        _EmissionColor ("Emission Color", Color) = (0,0,0,0)
        _BaseColorAlpha ("Base Alpha", Range(0,1)) = 1
        _MaskThreshold ("Mask Threshold", Range(0,1)) = 0
        _BlendMode ("Blend Mode", Int) = 0
        _UseMultistageBlend ("Use Multistage Blend", Int) = 0
        _UsesStencil ("Uses Stencil", Int) = 0
        _SrcBlend ("Src Blend", Float) = 5 // SrcAlpha
        _DstBlend ("Dst Blend", Float) = 10 // OneMinusSrcAlpha
        _BlendOp ("Blend Op", Float) = 0
        _ZWrite ("ZWrite", Float) = 0
        _StencilRef ("Stencil Ref", Float) = 0
        _StencilComp ("Stencil Comp", Float) = 3 // Always
        _StencilPass ("Stencil Pass", Float) = 0 // Keep
    }
    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Transparent" "Queue"="Transparent" }
        Pass
        {
            Name "NijiliveUnlit"
            Blend [_SrcBlend] [_DstBlend]
            BlendOp [_BlendOp]
            ZWrite [_ZWrite]
            Cull Off
            Stencil
            {
                Ref [_StencilRef]
                Comp [_StencilComp]
                Pass [_StencilPass]
            }

            HLSLINCLUDE
            #pragma vertex vert
            #pragma multi_compile_fog
            #pragma multi_compile __ NIJI_MRT

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_BaseMap); SAMPLER(sampler_BaseMap);
            TEXTURE2D(_MaskTex); SAMPLER(sampler_MaskTex);
            TEXTURE2D(_ExtraTex); SAMPLER(sampler_ExtraTex);

            float4 _BaseColor;
            float4 _ScreenTint;
            float4 _EmissionColor;
            float _BaseColorAlpha;
            float _MaskThreshold;
            int _BlendMode;
            int _UseMultistageBlend;
            int _UsesStencil;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
                UNITY_FOG_COORDS(1)
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.uv = float2(IN.uv.x, IN.uv.y);
                UNITY_TRANSFER_FOG(OUT, OUT.positionHCS);
                return OUT;
            }

            #if defined(NIJI_MRT)
                struct FragOut
                {
                    float4 c0 : SV_Target0;
                    float4 c1 : SV_Target1;
                    float4 c2 : SV_Target2;
                };
            #endif

            float3 computeColor(float2 uv, float fogCoord, out float alpha)
            {
                float4 baseSample  = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
                float4 maskSample  = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, uv);
                float4 extraSample = SAMPLE_TEXTURE2D(_ExtraTex, sampler_ExtraTex, uv);

                float maskFactor = maskSample.r >= _MaskThreshold ? 1.0 : 0.0;
                alpha = baseSample.a * _BaseColorAlpha * maskFactor;

                float3 color = baseSample.rgb * _BaseColor.rgb;
                if (_UseMultistageBlend != 0)
                {
                    color = lerp(color, color + extraSample.rgb, saturate(extraSample.a));
                }
                UNITY_APPLY_FOG(fogCoord, color);
                return color;
            }

            #if defined(NIJI_MRT)
                FragOut frag(Varyings IN)
                {
                    FragOut o;
                    float2 uv = IN.uv;
                    if (any(uv < 0.0) || any(uv > 1.0))
                    {
                        o.c0 = float4(0,0,0,0);
                        o.c1 = float4(0,0,0,0);
                        o.c2 = float4(0,0,0,0);
                        return o;
                    }
                    float alpha;
                    float3 color = computeColor(uv, IN.fogCoord, alpha);
                    o.c0 = float4(color, alpha);
                    o.c1 = float4(color, alpha); // emissive/extra placeholder
                    o.c2 = float4(0,0,0,0);
                    return o;
                }
            #else
                float4 frag(Varyings IN) : SV_Target
                {
                    float2 uv = IN.uv;
                    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0,0,0,0);
                    float alpha;
                    float3 color = computeColor(uv, IN.fogCoord, alpha);
                    return float4(color, alpha);
                }
            #endif
            ENDHLSL
            #pragma fragment frag
        }
    }
}
