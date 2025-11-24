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
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "IgnoreProjector"="True" }
        Pass
        {
            Name "NijiliveUnlitBuiltIn"
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

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog

            #include "UnityCG.cginc"

            sampler2D _BaseMap; float4 _BaseMap_ST;
            sampler2D _MaskTex;
            sampler2D _ExtraTex;

            float4 _BaseColor;
            float4 _ScreenTint;
            float4 _EmissionColor;
            float _BaseColorAlpha;
            float _MaskThreshold;
            int _BlendMode;
            int _UseMultistageBlend;
            int _UsesStencil;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                UNITY_FOG_COORDS(1)
                float4 vertex : SV_POSITION;
            };

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _BaseMap);
                //o.uv.y = 1.0 - o.uv.y; // Flip Y for consistency with URP shader logic
                UNITY_TRANSFER_FOG(o,o.vertex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float2 uv = i.uv;
                if (any(uv < 0.0) || any(uv > 1.0)) return fixed4(0,0,0,0);
                fixed4 baseSample = tex2D(_BaseMap, uv);
                fixed4 maskSample = tex2D(_MaskTex, uv);
                fixed4 extraSample = tex2D(_ExtraTex, uv);

                float maskFactor = maskSample.r >= _MaskThreshold ? 1.0 : 0.0;
                float alpha = baseSample.a * _BaseColorAlpha * maskFactor;

                float3 color = baseSample.rgb * _BaseColor.rgb;

                if (_UseMultistageBlend != 0)
                {
                    color = lerp(color, color + extraSample.rgb, saturate(extraSample.a));
                }

                color *= alpha;

                /*
                color += _ScreenTint.rgb;
                color += _EmissionColor.rgb;
                */

                UNITY_APPLY_FOG(i.fogCoord, color);
                return fixed4(color, alpha);
            }
            ENDCG
        }
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
            #pragma fragment frag
            #pragma multi_compile_fog

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

            float4 frag(Varyings IN) : SV_Target
            {
                float2 uv = IN.uv;
                if (any(uv < 0.0) || any(uv > 1.0)) return float4(0,0,0,0);

                float4 baseSample  = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv);
                float4 maskSample  = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, uv);
                float4 extraSample = SAMPLE_TEXTURE2D(_ExtraTex, sampler_ExtraTex, uv);

                float maskFactor = maskSample.r >= _MaskThreshold ? 1.0 : 0.0;
                float alpha = baseSample.a * _BaseColorAlpha * maskFactor;

                float3 color = baseSample.rgb * _BaseColor.rgb;

                if (_UseMultistageBlend != 0)
                {
                    color = lerp(color, color + extraSample.rgb, saturate(extraSample.a));
                }
                /*
                color += _ScreenTint.rgb;
                color += _EmissionColor.rgb;
                */
                UNITY_APPLY_FOG(IN.fogCoord, color);
                return float4(color, alpha);
            }
            ENDHLSL
        }
    }
}
