module nijilive.core.render.backends.directx12.pso_cache;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import std.exception : enforce;
import std.typecons : scoped;
import core.stdc.string : memcpy;

import aurora.directx.com : DXPtr;
import aurora.directx.d3d.d3dcommon : ID3DBlob;
import aurora.directx.d3d12;
import aurora.directx.d3d.d3dcompiler : D3DCompile;

import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.pipeline : PartRootSignature;
import nijilive.core.render.backends.directx12.render_targets : RenderTargets;
import nijilive.core.render.backends.directx12.dxhelpers;

enum PartPipelineMode : ubyte {
    standard,
    maskWrite,
    maskedContent,
}

private ID3DBlob compileShader(string sourceName, string sourceText, string profile, string entryPoint) {
    ID3DBlob blob = null;
    ID3DBlob errorBlob = null;
    auto hr = D3DCompile(
        sourceText.ptr,
        sourceText.length,
        sourceName.ptr,
        null,
        null,
        entryPoint.ptr,
        profile.ptr,
        0,
        0,
        &blob,
        &errorBlob);
    scope(exit) {
        if (errorBlob !is null) errorBlob.Release();
    }
    enforceHr(hr, "Failed to compile shader "~sourceName);
    return blob;
}

struct PartPipelineState {
private:
    DXPtr!ID3D12PipelineState[PartPipelineMode.max + 1] pipelines;

public:
    void initialize(DirectX12Device* device, PartRootSignature* rootSig, RenderTargets* targets) {
        if (device is null || device.device is null || rootSig is null) return;
        auto vs = scoped!ID3DBlob(compileShader("part_vs.hlsl", import("directx12/part_vs.hlsl"), "vs_5_0", "vs_main"));
        auto ps = scoped!ID3DBlob(compileShader("part_ps.hlsl", import("directx12/part_ps.hlsl"), "ps_5_0", "ps_main"));

        foreach (mode; [PartPipelineMode.standard, PartPipelineMode.maskWrite, PartPipelineMode.maskedContent]) {
            pipelines[mode] = createPipeline(device, rootSig, targets, vs, ps, mode);
        }
    }

    ID3D12PipelineState value(PartPipelineMode mode = PartPipelineMode.standard) {
        auto pso = pipelines[mode];
        return pso is null ? null : pso.value;
    }

    void shutdown() {
        pipelines[] = null;
    }

private:
    DXPtr!ID3D12PipelineState createPipeline(DirectX12Device* device, PartRootSignature* rootSig,
                                             RenderTargets* targets, ID3DBlob vs, ID3DBlob ps,
                                             PartPipelineMode mode) {
        D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC.init;
        desc.pRootSignature = rootSig.value();
        auto vsBytecode = D3D12_SHADER_BYTECODE(vs.GetBufferPointer(), vs.GetBufferSize());
        memcpy(&desc.VS, &vsBytecode, D3D12_SHADER_BYTECODE.sizeof);
        auto psBytecode = D3D12_SHADER_BYTECODE(ps.GetBufferPointer(), ps.GetBufferSize());
        memcpy(&desc.PS, &psBytecode, D3D12_SHADER_BYTECODE.sizeof);

        D3D12_INPUT_ELEMENT_DESC[6] inputElements = [
            D3D12_INPUT_ELEMENT_DESC("POSITION", 0, DXGI_FORMAT_R32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("POSITION", 1, DXGI_FORMAT_R32_FLOAT, 1, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("TEXCOORD", 0, DXGI_FORMAT_R32_FLOAT, 2, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("TEXCOORD", 1, DXGI_FORMAT_R32_FLOAT, 3, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("TEXCOORD", 2, DXGI_FORMAT_R32_FLOAT, 4, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("TEXCOORD", 3, DXGI_FORMAT_R32_FLOAT, 5, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
        ];
        auto layout = D3D12_INPUT_LAYOUT_DESC(
            cast(const D3D12_INPUT_ELEMENT_DESC*)inputElements.ptr,
            cast(uint)inputElements.length);
        memcpy(&desc.InputLayout, &layout, D3D12_INPUT_LAYOUT_DESC.sizeof);

        desc.BlendState = D3D12_BLEND_DESC.init;
        desc.BlendState.AlphaToCoverageEnable = false;
        foreach (i; 0 .. 3) {
            desc.BlendState.RenderTarget[i] = D3D12_RENDER_TARGET_BLEND_DESC.init;
            desc.BlendState.RenderTarget[i].BlendEnable = true;
            desc.BlendState.RenderTarget[i].SrcBlend = D3D12_BLEND_ONE;
            desc.BlendState.RenderTarget[i].DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            desc.BlendState.RenderTarget[i].BlendOp = D3D12_BLEND_OP_ADD;
            desc.BlendState.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE;
            desc.BlendState.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            desc.BlendState.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD;
            desc.BlendState.RenderTarget[i].RenderTargetWriteMask =
                (mode == PartPipelineMode.maskWrite) ? 0 : cast(uint)D3D12_COLOR_WRITE_ENABLE_ALL;
        }
        desc.SampleMask = uint.max;
        desc.RasterizerState = D3D12_RASTERIZER_DESC.init;
        desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        desc.DepthStencilState = D3D12_DEPTH_STENCIL_DESC.init;
        desc.DepthStencilState.DepthEnable = false;
        desc.DepthStencilState.StencilEnable = (mode != PartPipelineMode.standard);
        if (desc.DepthStencilState.StencilEnable) {
            desc.DepthStencilState.FrontFace.StencilReadMask = 0xFF;
            desc.DepthStencilState.FrontFace.StencilWriteMask = 0xFF;
            desc.DepthStencilState.BackFace = desc.DepthStencilState.FrontFace;
            if (mode == PartPipelineMode.maskWrite) {
                desc.DepthStencilState.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;
                desc.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_REPLACE;
            } else {
                desc.DepthStencilState.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC_EQUAL;
                desc.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_KEEP;
            }
        }
        desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        desc.NumRenderTargets = 3;
        desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.RTVFormats[1] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.RTVFormats[2] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.DSVFormat = DXGI_FORMAT_D24_UNORM_S8_UINT;
        desc.SampleDesc.Count = 1;

        ID3D12PipelineState rawPso = null;
        enforceHr(device.device.CreateGraphicsPipelineState(&desc, iid!ID3D12PipelineState, cast(void**)&rawPso),
            "CreateGraphicsPipelineState (part) failed");
        return new DXPtr!ID3D12PipelineState(rawPso);
    }
}

struct MaskPipelineState {
private:
    DXPtr!ID3D12PipelineState pipeline;

public:
    void initialize(DirectX12Device* device, PartRootSignature* rootSig) {
        if (pipeline !is null || device is null || device.device is null || rootSig is null) return;
        auto vs = scoped!ID3DBlob(compileShader("mask_vs.hlsl", import("directx12/mask_vs.hlsl"), "vs_5_0", "vs_main"));
        auto ps = scoped!ID3DBlob(compileShader("mask_ps.hlsl", import("directx12/mask_ps.hlsl"), "ps_5_0", "ps_main"));

        D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC.init;
        desc.pRootSignature = rootSig.value();
        auto vsBytecode = D3D12_SHADER_BYTECODE(vs.GetBufferPointer(), vs.GetBufferSize());
        memcpy(&desc.VS, &vsBytecode, D3D12_SHADER_BYTECODE.sizeof);
        auto psBytecode = D3D12_SHADER_BYTECODE(ps.GetBufferPointer(), ps.GetBufferSize());
        memcpy(&desc.PS, &psBytecode, D3D12_SHADER_BYTECODE.sizeof);

        D3D12_INPUT_ELEMENT_DESC[4] inputElements = [
            D3D12_INPUT_ELEMENT_DESC("POSITION", 0, DXGI_FORMAT_R32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("POSITION", 1, DXGI_FORMAT_R32_FLOAT, 1, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("TEXCOORD", 2, DXGI_FORMAT_R32_FLOAT, 4, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
            D3D12_INPUT_ELEMENT_DESC("TEXCOORD", 3, DXGI_FORMAT_R32_FLOAT, 5, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0),
        ];
        auto layout = D3D12_INPUT_LAYOUT_DESC(
            cast(const D3D12_INPUT_ELEMENT_DESC*)inputElements.ptr,
            cast(uint)inputElements.length);
        memcpy(&desc.InputLayout, &layout, D3D12_INPUT_LAYOUT_DESC.sizeof);

        desc.BlendState = D3D12_BLEND_DESC.init;
        foreach (i; 0 .. 3) {
            desc.BlendState.RenderTarget[i].RenderTargetWriteMask = 0;
        }
        desc.SampleMask = uint.max;
        desc.RasterizerState = D3D12_RASTERIZER_DESC.init;
        desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        desc.DepthStencilState = D3D12_DEPTH_STENCIL_DESC.init;
        desc.DepthStencilState.DepthEnable = false;
        desc.DepthStencilState.StencilEnable = true;
        desc.DepthStencilState.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC_ALWAYS;
        desc.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_REPLACE;
        desc.DepthStencilState.FrontFace.StencilReadMask = 0xFF;
        desc.DepthStencilState.FrontFace.StencilWriteMask = 0xFF;
        desc.DepthStencilState.BackFace = desc.DepthStencilState.FrontFace;
        desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        desc.NumRenderTargets = 3;
        desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.RTVFormats[1] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.RTVFormats[2] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.DSVFormat = DXGI_FORMAT_D24_UNORM_S8_UINT;
        desc.SampleDesc.Count = 1;

        ID3D12PipelineState rawPso = null;
        enforceHr(device.device.CreateGraphicsPipelineState(&desc, iid!ID3D12PipelineState, cast(void**)&rawPso),
            "CreateGraphicsPipelineState (mask) failed");
        pipeline = new DXPtr!ID3D12PipelineState(rawPso);
    }

    ID3D12PipelineState value() {
        return pipeline is null ? null : pipeline.value;
    }

    void shutdown() {
        pipeline = null;
    }
}

struct CompositePipelineState {
private:
    DXPtr!ID3D12PipelineState pipeline;

public:
    void initialize(DirectX12Device* device, PartRootSignature* rootSig) {
        if (pipeline !is null || device is null || device.device is null || rootSig is null) return;
        auto vs = scoped!ID3DBlob(compileShader("composite_vs.hlsl", import("directx12/composite_vs.hlsl"), "vs_5_0", "vs_main"));
        auto ps = scoped!ID3DBlob(compileShader("composite_ps.hlsl", import("directx12/composite_ps.hlsl"), "ps_5_0", "ps_main"));

        D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC.init;
        desc.pRootSignature = rootSig.value();
        auto vsBytecode = D3D12_SHADER_BYTECODE(vs.GetBufferPointer(), vs.GetBufferSize());
        memcpy(&desc.VS, &vsBytecode, D3D12_SHADER_BYTECODE.sizeof);
        auto psBytecode = D3D12_SHADER_BYTECODE(ps.GetBufferPointer(), ps.GetBufferSize());
        memcpy(&desc.PS, &psBytecode, D3D12_SHADER_BYTECODE.sizeof);
        desc.BlendState = D3D12_BLEND_DESC.init;
        foreach (i; 0 .. 3) {
            desc.BlendState.RenderTarget[i] = D3D12_RENDER_TARGET_BLEND_DESC.init;
            desc.BlendState.RenderTarget[i].BlendEnable = true;
            desc.BlendState.RenderTarget[i].SrcBlend = D3D12_BLEND_ONE;
            desc.BlendState.RenderTarget[i].DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            desc.BlendState.RenderTarget[i].BlendOp = D3D12_BLEND_OP_ADD;
            desc.BlendState.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE;
            desc.BlendState.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            desc.BlendState.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD;
            desc.BlendState.RenderTarget[i].RenderTargetWriteMask = cast(uint)D3D12_COLOR_WRITE_ENABLE_ALL;
        }
        desc.SampleMask = uint.max;
        desc.RasterizerState = D3D12_RASTERIZER_DESC.init;
        desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        desc.DepthStencilState = D3D12_DEPTH_STENCIL_DESC.init;
        desc.DepthStencilState.DepthEnable = false;
        desc.DepthStencilState.StencilEnable = false;
        desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        desc.NumRenderTargets = 3;
        desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.RTVFormats[1] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.RTVFormats[2] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.DSVFormat = DXGI_FORMAT_D24_UNORM_S8_UINT;
        desc.SampleDesc.Count = 1;

        ID3D12PipelineState rawPso = null;
        enforceHr(device.device.CreateGraphicsPipelineState(&desc, iid!ID3D12PipelineState, cast(void**)&rawPso),
            "CreateGraphicsPipelineState (composite) failed");
        pipeline = new DXPtr!ID3D12PipelineState(rawPso);
    }

    ID3D12PipelineState value() {
        return pipeline is null ? null : pipeline.value;
    }

    void shutdown() {
        pipeline = null;
    }
}

struct QuadPipelineState {
private:
    DXPtr!ID3D12PipelineState pipeline;

public:
    void initialize(DirectX12Device* device, PartRootSignature* rootSig, string vsSource, string psSource,
                    string vsName, string psName) {
        if (pipeline !is null || device is null || device.device is null || rootSig is null) return;
        auto vs = scoped!ID3DBlob(compileShader(vsName, vsSource, "vs_5_0", "vs_main"));
        auto ps = scoped!ID3DBlob(compileShader(psName, psSource, "ps_5_0", "ps_main"));

        D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = D3D12_GRAPHICS_PIPELINE_STATE_DESC.init;
        desc.pRootSignature = rootSig.value();
        auto vsBytecode = D3D12_SHADER_BYTECODE(vs.GetBufferPointer(), vs.GetBufferSize());
        memcpy(&desc.VS, &vsBytecode, D3D12_SHADER_BYTECODE.sizeof);
        auto psBytecode = D3D12_SHADER_BYTECODE(ps.GetBufferPointer(), ps.GetBufferSize());
        memcpy(&desc.PS, &psBytecode, D3D12_SHADER_BYTECODE.sizeof);
        desc.BlendState = D3D12_BLEND_DESC.init;
        foreach (i; 0 .. 3) {
            desc.BlendState.RenderTarget[i] = D3D12_RENDER_TARGET_BLEND_DESC.init;
            desc.BlendState.RenderTarget[i].BlendEnable = true;
            desc.BlendState.RenderTarget[i].SrcBlend = D3D12_BLEND_ONE;
            desc.BlendState.RenderTarget[i].DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            desc.BlendState.RenderTarget[i].BlendOp = D3D12_BLEND_OP_ADD;
            desc.BlendState.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE;
            desc.BlendState.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            desc.BlendState.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD;
            desc.BlendState.RenderTarget[i].RenderTargetWriteMask = cast(uint)D3D12_COLOR_WRITE_ENABLE_ALL;
        }
        desc.SampleMask = uint.max;
        desc.RasterizerState = D3D12_RASTERIZER_DESC.init;
        desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        desc.DepthStencilState = D3D12_DEPTH_STENCIL_DESC.init;
        desc.DepthStencilState.DepthEnable = false;
        desc.DepthStencilState.StencilEnable = false;
        desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        desc.NumRenderTargets = 3;
        desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.RTVFormats[1] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.RTVFormats[2] = DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.DSVFormat = DXGI_FORMAT_D24_UNORM_S8_UINT;
        desc.SampleDesc.Count = 1;

        ID3D12PipelineState rawPso = null;
        enforceHr(device.device.CreateGraphicsPipelineState(&desc, iid!ID3D12PipelineState, cast(void**)&rawPso),
            "CreateGraphicsPipelineState (quad) failed");
        pipeline = new DXPtr!ID3D12PipelineState(rawPso);
    }

    ID3D12PipelineState value() {
        return pipeline is null ? null : pipeline.value;
    }

    void shutdown() {
        pipeline = null;
    }
}

}

}
