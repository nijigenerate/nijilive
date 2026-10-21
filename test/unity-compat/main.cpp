#define NOMINMAX
#include <windows.h>
#include <core/unity_native.hpp>
#include <iostream>
#include <set>
#include <stdexcept>
#include <cstring>
#include <cmath>
void check(bool condition,const char* text) {if(!condition)throw std::runtime_error(text);}
std::set<size_t> textures;
size_t nextTexture=1;
size_t createTexture(int,int,int,int,int,bool,bool,void*) {auto id=nextTexture++;textures.insert(id);return id;}
void updateTexture(size_t id,const uint8_t*,size_t,int,int,int,void*) {check(textures.count(id)>0,"updating unknown texture");}
void releaseTexture(size_t id,void*) {check(textures.erase(id)>0,"releasing unknown texture");}
NjgResult expectedLayout(NjgWasmLayout* outLayout) {
    if (!outLayout) return NjgResult::InvalidArgument;

    NjgWasmLayout out{};
    out.sizeQueued = static_cast<uint32_t>(sizeof(NjgQueuedCommand));
    out.offQueuedPart = static_cast<uint32_t>(offsetof(NjgQueuedCommand, partPacket));
    out.offQueuedMaskApply = static_cast<uint32_t>(offsetof(NjgQueuedCommand, maskApplyPacket));
    out.offQueuedDynamic = static_cast<uint32_t>(offsetof(NjgQueuedCommand, dynamicPass));
    out.offQueuedUsesStencil = static_cast<uint32_t>(offsetof(NjgQueuedCommand, usesStencil));

    out.sizePart = static_cast<uint32_t>(sizeof(NjgPartDrawPacket));
    out.offPartTextureHandles = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, textureHandles));
    out.offPartTextureCount = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, textureCount));
    out.offPartOrigin = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, origin));
    out.offPartVertexOffset = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, vertexOffset));
    out.offPartVertexStride = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, vertexAtlasStride));
    out.offPartUvOffset = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, uvOffset));
    out.offPartUvStride = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, uvAtlasStride));
    out.offPartDeformOffset = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, deformOffset));
    out.offPartDeformStride = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, deformAtlasStride));
    out.offPartIndexHandle = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, indexHandle));
    out.offPartIndicesPtr = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, indices));
    out.offPartIndexCount = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, indexCount));
    out.offPartVertexCount = static_cast<uint32_t>(offsetof(NjgPartDrawPacket, vertexCount));

    out.sizeMaskDraw = static_cast<uint32_t>(sizeof(NjgMaskDrawPacket));
    out.offMaskDrawIndicesPtr = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, indices));
    out.offMaskDrawIndexCount = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, indexCount));
    out.offMaskDrawVertexOffset = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, vertexOffset));
    out.offMaskDrawVertexStride = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, vertexAtlasStride));
    out.offMaskDrawDeformOffset = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, deformOffset));
    out.offMaskDrawDeformStride = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, deformAtlasStride));
    out.offMaskDrawIndexHandle = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, indexHandle));
    out.offMaskDrawVertexCount = static_cast<uint32_t>(offsetof(NjgMaskDrawPacket, vertexCount));

    out.sizeMaskApply = static_cast<uint32_t>(sizeof(NjgMaskApplyPacket));
    out.offMaskKind = static_cast<uint32_t>(offsetof(NjgMaskApplyPacket, kind));
    out.offMaskIsDodge = static_cast<uint32_t>(offsetof(NjgMaskApplyPacket, isDodge));
    out.offMaskPartPacket = static_cast<uint32_t>(offsetof(NjgMaskApplyPacket, partPacket));
    out.offMaskMaskPacket = static_cast<uint32_t>(offsetof(NjgMaskApplyPacket, maskPacket));

    out.sizeDynamicPass = static_cast<uint32_t>(sizeof(NjgDynamicCompositePass));
    out.offDynTextures = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, textures));
    out.offDynTextureCount = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, textureCount));
    out.offDynStencil = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, stencil));
    out.offDynScale = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, scale));
    out.offDynRotationZ = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, rotationZ));
    out.offDynAutoScaled = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, autoScaled));
    out.offDynOrigBuffer = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, origBuffer));
    out.offDynOrigViewport = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, origViewport));
    out.offDynDrawBufferCount = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, drawBufferCount));
    out.offDynHasStencil = static_cast<uint32_t>(offsetof(NjgDynamicCompositePass, hasStencil));

    *outLayout = out;
    return NjgResult::Ok;
}

int main(int argc,char** argv) {try {
    check(argc>=2,"usage: unity_compat DLL [MODEL.inp]");
    auto dll=LoadLibraryA(argv[1]); check(dll!=nullptr,"cannot load native DLL");
#define API(name) auto name=reinterpret_cast<decltype(&::name)>(GetProcAddress(dll,#name)); check(name!=nullptr,#name " missing")
    API(njgRuntimeInit);
    API(njgRuntimeTerm);
    API(njgCreateRenderer);
    API(njgDestroyRenderer);
    API(njgLoadPuppet);
    API(njgUnloadPuppet);
    API(njgGetParameters);
    API(njgQuery);
    API(njgUpdateParameters);
    API(njgGetPuppetExtData);
    API(njgPlayAnimation);
    API(njgPauseAnimation);
    API(njgStopAnimation);
    API(njgSeekAnimation);
    API(njgSetPuppetScale);
    API(njgSetPuppetTranslation);
    API(njgBeginFrame);
    API(njgTickPuppet);
    API(njgEmitCommands);
    API(njgGetSharedBuffers);
    API(njgGetSharedBufferState);
    API(njgGetRenderTargets);
    API(njgSetLogCallback);
    API(njgFlushCommandBuffer);
    API(njgGetGcHeapSize);
    API(njgGetTextureStats);
    API(njgGetWasmLayout);

    NjgWasmLayout expected{},actual{};expectedLayout(&expected);
    check(njgGetWasmLayout(&actual)==NjgResult::Ok,"layout query failed");
    if(std::memcmp(&actual,&expected,sizeof(actual))) {
        auto a=reinterpret_cast<uint32_t*>(&actual),e=reinterpret_cast<uint32_t*>(&expected);
        for(size_t i=0;i<sizeof(actual)/4;++i)if(a[i]!=e[i])std::cerr<<"layout "<<i<<": actual="<<a[i]<<" expected="<<e[i]<<'\n';
        throw std::runtime_error("native layout differs from nicxlive header");
    }
    check(njgGetWasmLayout(nullptr)==NjgResult::InvalidArgument,"null layout accepted");
    std::cout<<"PASS all exports and all layout fields\n";
    if(argc==2)return 0;
    njgRuntimeInit(); UnityRendererConfig cfg{512,512};UnityResourceCallbacks callbacks{nullptr,createTexture,updateTexture,releaseTexture};
    void* renderer=nullptr;void* puppet=nullptr;
    check(njgCreateRenderer(&cfg,&callbacks,&renderer)==NjgResult::Ok,"create renderer failed");
    void* otherRenderer=nullptr;
    check(njgCreateRenderer(&cfg,&callbacks,&otherRenderer)==NjgResult::Ok,"create second renderer failed");
    check(njgLoadPuppet(renderer,argv[2],&puppet)==NjgResult::Ok,"load real model failed");
    size_t count=0;check(njgGetParameters(puppet,nullptr,0,&count)==NjgResult::Ok && count>0,"model parameters missing");
    std::vector<NjgParameterInfo> params(count);check(njgGetParameters(puppet,params.data(),count,&count)==NjgResult::Ok,"read parameters failed");
    SharedBufferState before{},after{};njgGetSharedBufferState(renderer,&before);
    for(int frame=0;frame<3;++frame) {
        FrameConfig fc{512+frame*16,512+frame*16};
        check(njgBeginFrame(renderer,&fc)==NjgResult::Ok,"begin failed");
        check(njgTickPuppet(puppet,1.0/60)==NjgResult::Ok,"tick failed");
        CommandQueueView view{};check(njgEmitCommands(renderer,&view)==NjgResult::Ok && view.count>0,"no commands");
        SharedBufferSnapshot shared{};check(njgGetSharedBuffers(renderer,&shared)==NjgResult::Ok,"shared buffers failed");
        check(shared.vertices.length==2*shared.vertexCount,"invalid vertex SoA layout");
        size_t draws=0;
        for(size_t i=0;i<view.count;++i) {
            const auto& cmd=view.commands[i];
            check(static_cast<uint32_t>(cmd.kind)<=6,"invalid command kind");
            if(cmd.kind!=NjgRenderCommandKind::DrawPart)continue;
            const auto& part=cmd.partPacket;
            check(std::isfinite(part.opacity) && part.textureCount<=3,"corrupt draw packet");
            check(part.vertexOffset+part.vertexCount<=shared.vertexCount,"vertex range outside atlas");
            for(size_t t=0;t<part.textureCount;++t)if(part.textureHandles[t])check(textures.count(part.textureHandles[t])>0,"unknown draw texture handle");
            for(size_t j=0;j<part.indexCount;++j)check(part.indices[j]<part.vertexCount,"index outside vertices");
            if(part.indexCount)++draws;
        }
        check(draws>0,"no valid draw geometry");
        njgGetSharedBufferState(renderer,&after);
        check(after.deformRevision!=before.deformRevision,"deformation revision did not change");before=after;
        auto targets=njgGetRenderTargets(renderer);check(targets.viewportWidth==fc.viewportWidth,"viewport resize missing");
        std::cout<<"frame "<<frame<<" commands="<<view.count<<" draws="<<draws<<" vertices="<<shared.vertexCount<<'\n';
        njgFlushCommandBuffer(renderer);
    }
    check(njgUnloadPuppet(otherRenderer,puppet)==NjgResult::InvalidArgument,"cross-renderer unload accepted");
    auto stats=njgGetTextureStats(renderer);check(stats.current==textures.size(),"texture accounting differs from callbacks");
    check(njgUnloadPuppet(renderer,puppet)==NjgResult::Ok,"unload failed");
    check(njgUnloadPuppet(renderer,puppet)==NjgResult::InvalidArgument,"double unload accepted");
    njgDestroyRenderer(renderer);njgDestroyRenderer(otherRenderer);
    check(textures.empty(),"external textures retained after renderer destruction");
    njgRuntimeTerm();
    std::cout<<"PASS real-model ABI commands, shared buffers, resize, unload and callbacks\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
