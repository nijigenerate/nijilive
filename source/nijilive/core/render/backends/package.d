module nijilive.core.render.backends;

import std.exception : enforce;

import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.render.commands : PartDrawPacket, CompositeDrawPacket, MaskApplyPacket,
    MaskDrawPacket, DynamicCompositeSurface, DynamicCompositePass;
import nijilive.core.meshdata : MeshData;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.math : vec2, vec3, vec4, rect, mat4, Vec2Array, Vec3Array, Vec4Array;
import nijilive.math.camera : Camera;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;

/// GPU周りの共有状態を Backend がキャッシュするための構造体
alias RenderResourceHandle = size_t;

struct RenderGpuState {
    RenderResourceHandle framebuffer;
    RenderResourceHandle[8] drawBuffers;
    ubyte drawBufferCount;
    bool[4] colorMask;
    bool blendEnabled;
}

/// Base type for backend-provided opaque handles.
class RenderBackendHandle { }

/// Handle for shader programs managed by a RenderBackend.
class RenderShaderHandle : RenderBackendHandle { }

/// Handle for texture resources managed by a RenderBackend.
class RenderTextureHandle : RenderBackendHandle { }

enum BackendEnum {
    OpenGL,
    DirectX12,
    Vulkan,
}

version (Windows) {
    version (UseDirectX) {
        version = RenderBackendDirectX12;
    }
}

/*
class RenderingBackend(BackendEnum backendType) if (backendType != BackendEnum.OpenGL){
    private auto backendUnsupported(T = void)(string func) {
        enforce(false, "Rendering backend "~backendType.stringof~" does not implement "~func);
        static if (!is(T == void)) {
            return T.init;
        }
    }

    void initializeRenderer() { backendUnsupported(__FUNCTION__); }
    void resizeViewportTargets(int width, int height) { backendUnsupported(__FUNCTION__); }
    void dumpViewport(ref ubyte[] data, int width, int height) { backendUnsupported(__FUNCTION__); }
    void beginScene() { backendUnsupported(__FUNCTION__); }
    void endScene() { backendUnsupported(__FUNCTION__); }
    void postProcessScene() { backendUnsupported(__FUNCTION__); }

    void initializeDrawableResources() { backendUnsupported(__FUNCTION__); }
    void bindDrawableVao() { backendUnsupported(__FUNCTION__); }
    void createDrawableBuffers(out uint ibo) { backendUnsupported(__FUNCTION__); }
    void uploadDrawableIndices(uint ibo, ushort[] indices) { backendUnsupported(__FUNCTION__); }
    void uploadSharedVertexBuffer(Vec2Array vertices) { backendUnsupported(__FUNCTION__); }
    void uploadSharedUvBuffer(Vec2Array uvs) { backendUnsupported(__FUNCTION__); }
    void uploadSharedDeformBuffer(Vec2Array deform) { backendUnsupported(__FUNCTION__); }
    void drawDrawableElements(uint ibo, size_t indexCount) { backendUnsupported(__FUNCTION__); }

    bool supportsAdvancedBlend() { return backendUnsupported!bool(__FUNCTION__); }
    bool supportsAdvancedBlendCoherent() { return backendUnsupported!bool(__FUNCTION__); }
    void setAdvancedBlendCoherent(bool enabled) { backendUnsupported(__FUNCTION__); }
    void setLegacyBlendMode(BlendMode mode) { backendUnsupported(__FUNCTION__); }
    void setAdvancedBlendEquation(BlendMode mode) { backendUnsupported(__FUNCTION__); }
    void issueBlendBarrier() { backendUnsupported(__FUNCTION__); }
    void initDebugRenderer() { backendUnsupported(__FUNCTION__); }
    void setDebugPointSize(float size) { backendUnsupported(__FUNCTION__); }
    void setDebugLineWidth(float size) { backendUnsupported(__FUNCTION__); }
    void uploadDebugBuffer(Vec3Array points, ushort[] indices) { backendUnsupported(__FUNCTION__); }
    void setDebugExternalBuffer(uint vbo, uint ibo, int count) { backendUnsupported(__FUNCTION__); }
    void drawDebugPoints(vec4 color, mat4 mvp) { backendUnsupported(__FUNCTION__); }
    void drawDebugLines(vec4 color, mat4 mvp) { backendUnsupported(__FUNCTION__); }

    void drawPartPacket(ref PartDrawPacket packet) { backendUnsupported(__FUNCTION__); }
    void drawMaskPacket(ref MaskDrawPacket packet) { backendUnsupported(__FUNCTION__); }
    void beginDynamicComposite(DynamicCompositePass pass) { backendUnsupported(__FUNCTION__); }
    void endDynamicComposite(DynamicCompositePass pass) { backendUnsupported(__FUNCTION__); }
    void destroyDynamicComposite(DynamicCompositeSurface surface) { backendUnsupported(__FUNCTION__); }
    void beginMask(bool useStencil) { backendUnsupported(__FUNCTION__); }
    void applyMask(ref MaskApplyPacket packet) { backendUnsupported(__FUNCTION__); }
    void beginMaskContent() { backendUnsupported(__FUNCTION__); }
    void endMask() { backendUnsupported(__FUNCTION__); }
    void beginComposite() { backendUnsupported(__FUNCTION__); }
    void drawCompositeQuad(ref CompositeDrawPacket packet) { backendUnsupported(__FUNCTION__); }
    void endComposite() { backendUnsupported(__FUNCTION__); }
    void drawTextureAtPart(Texture texture, Part part) { backendUnsupported(__FUNCTION__); }
    void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                               vec3 color, vec3 screenColor) { backendUnsupported(__FUNCTION__); }
    void drawTextureAtRect(Texture texture, rect area, rect uvs,
                           float opacity, vec3 color, vec3 screenColor,
                           Shader shader = null, Camera cam = null) { backendUnsupported(__FUNCTION__); }
    uint framebufferHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint renderImageHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint compositeFramebufferHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint compositeImageHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint mainAlbedoHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint mainEmissiveHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint mainBumpHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint compositeEmissiveHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint compositeBumpHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendFramebufferHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendAlbedoHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendEmissiveHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendBumpHandle() { return backendUnsupported!uint(__FUNCTION__); }
    void addBasicLightingPostProcess() { backendUnsupported(__FUNCTION__); }
    void setDifferenceAggregationEnabled(bool enabled) { backendUnsupported(__FUNCTION__); }
    bool isDifferenceAggregationEnabled() { return backendUnsupported!bool(__FUNCTION__); }
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) { backendUnsupported(__FUNCTION__); }
    DifferenceEvaluationRegion getDifferenceAggregationRegion() { return backendUnsupported!DifferenceEvaluationRegion(__FUNCTION__); }
    bool evaluateDifferenceAggregation(uint texture, int width, int height) { return backendUnsupported!bool(__FUNCTION__); }
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) { return backendUnsupported!bool(__FUNCTION__); }

    RenderShaderHandle createShader(string vertexSource, string fragmentSource) { return backendUnsupported!RenderShaderHandle(__FUNCTION__); }
    void destroyShader(RenderShaderHandle shader) { backendUnsupported(__FUNCTION__); }
    void useShader(RenderShaderHandle shader) { backendUnsupported(__FUNCTION__); }
    int getShaderUniformLocation(RenderShaderHandle shader, string name) { return backendUnsupported!int(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, bool value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, int value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, float value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value) { backendUnsupported(__FUNCTION__); }

    RenderTextureHandle createTextureHandle() { return backendUnsupported!RenderTextureHandle(__FUNCTION__); }
    void destroyTextureHandle(RenderTextureHandle texture) { backendUnsupported(__FUNCTION__); }
    void bindTextureHandle(RenderTextureHandle texture, uint unit) { backendUnsupported(__FUNCTION__); }
    void uploadTextureData(RenderTextureHandle texture, int width, int height, int inChannels,
                           int outChannels, bool stencil, ubyte[] data) { backendUnsupported(__FUNCTION__); }
    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width, int height,
                             int channels, ubyte[] data) { backendUnsupported(__FUNCTION__); }
    void generateTextureMipmap(RenderTextureHandle texture) { backendUnsupported(__FUNCTION__); }
    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering) { backendUnsupported(__FUNCTION__); }
    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) { backendUnsupported(__FUNCTION__); }
    void applyTextureAnisotropy(RenderTextureHandle texture, float value) { backendUnsupported(__FUNCTION__); }
    float maxTextureAnisotropy() { return backendUnsupported!float(__FUNCTION__); }
    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                         ubyte[] buffer) { backendUnsupported(__FUNCTION__); }
    size_t textureNativeHandle(RenderTextureHandle texture) { return backendUnsupported!size_t(__FUNCTION__); }
}
*/
version (RenderBackendOpenGL) {
    enum SelectedBackend = BackendEnum.OpenGL;
} else version (RenderBackendDirectX12) {
    enum SelectedBackend = BackendEnum.DirectX12;
} else version (RenderBackendVulkan) {
    enum SelectedBackend = BackendEnum.Vulkan;
} else {
    enum SelectedBackend = BackendEnum.OpenGL;
}

version (UseQueueBackend) {
    enum bool SelectedBackendIsOpenGL = false;
} else {
    enum bool SelectedBackendIsOpenGL = SelectedBackend == BackendEnum.OpenGL;
}

version (InDoesRender) {
    version (UseQueueBackend) {
        public import nijilive.core.render.backends.queue;
    } else {
        public import nijilive.core.render.backends.opengl;
        version (RenderBackendDirectX12) {
            public import nijilive.core.render.backends.directx12;
        }
    }
}

version (UseQueueBackend) {
    static import nijilive.core.render.backends.queue;
} else {
    static import nijilive.core.render.backends.opengl;
}

version (UseQueueBackend) {
    import nijilive.core.render.backends.queue;
    alias RenderBackend = nijilive.core.render.backends.queue.RenderingBackend!(BackendEnum.OpenGL);
} else {
    template RenderingBackend(BackendEnum backendType) {
        static if (backendType == BackendEnum.OpenGL) {
            alias RenderingBackend = nijilive.core.render.backends.opengl.RenderingBackend!(backendType);
        } else static if (backendType == BackendEnum.DirectX12) {
            alias RenderingBackend = nijilive.core.render.backends.directx12.RenderingBackend!(backendType);
        } else {
            enum msg = "RenderingBackend!("~backendType.stringof~") is not implemented. Available options: BackendEnum.OpenGL, BackendEnum.DirectX12.";
            pragma(msg, msg);
            static assert(backendType == BackendEnum.OpenGL || backendType == BackendEnum.DirectX12, msg);
        }
    }

    alias RenderBackend = RenderingBackend!(SelectedBackend);
}
