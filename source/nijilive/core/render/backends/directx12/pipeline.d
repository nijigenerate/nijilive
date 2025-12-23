module nijilive.core.render.backends.directx12.pipeline;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import aurora.directx.com : DXPtr;
import aurora.directx.d3d.d3dcommon : ID3DBlob;
import aurora.directx.d3d12;

import core.stdc.string : memcpy;
import std.exception : enforce;

import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.dxhelpers;

/// Helper around the part root signature object.
struct PartRootSignature {
private:
    DXPtr!ID3D12RootSignature rootSignature;

public:
    void initialize(DirectX12Device* device) {
        if (rootSignature !is null || device is null || device.device is null) {
            return;
        }

        D3D12_DESCRIPTOR_RANGE[2] descriptorRanges;
        descriptorRanges[0] = D3D12_DESCRIPTOR_RANGE.init;
        descriptorRanges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        descriptorRanges[0].NumDescriptors = 3;
        descriptorRanges[0].BaseShaderRegister = 0;
        descriptorRanges[0].RegisterSpace = 0;
        descriptorRanges[0].OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;
        descriptorRanges[1] = D3D12_DESCRIPTOR_RANGE.init;
        descriptorRanges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        descriptorRanges[1].NumDescriptors = 3;
        descriptorRanges[1].BaseShaderRegister = 3;
        descriptorRanges[1].RegisterSpace = 0;
        descriptorRanges[1].OffsetInDescriptorsFromTableStart = D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;

        D3D12_ROOT_PARAMETER[4] parameters;
        parameters[0] = D3D12_ROOT_PARAMETER.init;
        parameters[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameters[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        auto table0 = D3D12_ROOT_DESCRIPTOR_TABLE(
            1,
            cast(const D3D12_DESCRIPTOR_RANGE*)&descriptorRanges[0]);
        memcpy(&parameters[0].DescriptorTable, &table0, D3D12_ROOT_DESCRIPTOR_TABLE.sizeof);
        parameters[1] = D3D12_ROOT_PARAMETER.init;
        parameters[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameters[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        auto table1 = D3D12_ROOT_DESCRIPTOR_TABLE(
            1,
            cast(const D3D12_DESCRIPTOR_RANGE*)&descriptorRanges[1]);
        memcpy(&parameters[1].DescriptorTable, &table1, D3D12_ROOT_DESCRIPTOR_TABLE.sizeof);
        parameters[2] = D3D12_ROOT_PARAMETER.init;
        parameters[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        parameters[2].Descriptor.ShaderRegister = 0;
        parameters[2].Descriptor.RegisterSpace = 0;
        parameters[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        parameters[3] = D3D12_ROOT_PARAMETER.init;
        parameters[3].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
        parameters[3].Descriptor.ShaderRegister = 0;
        parameters[3].Descriptor.RegisterSpace = 1;
        parameters[3].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_STATIC_SAMPLER_DESC sampler = D3D12_STATIC_SAMPLER_DESC.init;
        sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.MipLODBias = 0.0f;
        sampler.MaxAnisotropy = 1;
        sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
        sampler.BorderColor = D3D12_STATIC_BORDER_COLOR_OPAQUE_WHITE;
        sampler.MinLOD = 0.0f;
        sampler.MaxLOD = D3D12_FLOAT32_MAX;
        sampler.ShaderRegister = 0;
        sampler.RegisterSpace = 0;
        sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_ROOT_SIGNATURE_DESC rootDesc = D3D12_ROOT_SIGNATURE_DESC.init;
        rootDesc.NumParameters = cast(uint)parameters.length;
        (*cast(const(D3D12_ROOT_PARAMETER)**)&rootDesc.pParameters) = parameters.ptr;
        rootDesc.NumStaticSamplers = 1;
        (*cast(const(D3D12_STATIC_SAMPLER_DESC)**)&rootDesc.pStaticSamplers) = &sampler;
        rootDesc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

        ID3DBlob serialized = null;
        ID3DBlob errorBlob = null;
        auto hr = D3D12SerializeRootSignature(
            &rootDesc,
            D3D_ROOT_SIGNATURE_VERSION.VERSION_1_0,
            &serialized,
            &errorBlob
        );
        scope(exit) {
            if (serialized !is null) serialized.Release();
            if (errorBlob !is null) errorBlob.Release();
        }
        if (dxFailed(hr)) {
            string errorMessage = "D3D12SerializeRootSignature failed";
            if (errorBlob !is null) {
                auto ptr = cast(const(char)*)errorBlob.GetBufferPointer();
                auto len = errorBlob.GetBufferSize();
                errorMessage ~= ": " ~ (ptr[0 .. len].idup);
            } else {
                errorMessage ~= " (hr=" ~ hrMessage(hr) ~ ")";
            }
            enforce(false, errorMessage);
        }

        ID3D12RootSignature rawRoot = null;
        enforceHr(device.device.CreateRootSignature(
            0,
            serialized.GetBufferPointer(),
            serialized.GetBufferSize(),
            iid!ID3D12RootSignature,
            cast(void**)&rawRoot
        ), "CreateRootSignature failed");
        rootSignature = new DXPtr!ID3D12RootSignature(rawRoot);
    }

    void shutdown() {
        rootSignature = null;
    }

    ID3D12RootSignature value() {
        return rootSignature is null ? null : rootSignature.value;
    }
}

}

}
