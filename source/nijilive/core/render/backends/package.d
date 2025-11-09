module nijilive.core.render.backends;

import nijilive.core.nodes : Node;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.render.commands : PartDrawPacket, CompositeDrawPacket, MaskApplyPacket,
    MaskDrawPacket;
import nijilive.core.meshdata : MeshData;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.math : vec2, vec3, vec4, rect, mat4;
import nijilive.math.camera : Camera;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;

/// GPU周りの共有状態を Backend がキャッシュするための構造体
struct RenderGpuState {
    uint framebuffer;
    uint[8] drawBuffers;
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

/// Backend abstraction executed by RenderCommand implementations.
interface RenderBackend {
    void initializeRenderer();
    void resizeViewportTargets(int width, int height);
    void dumpViewport(ref ubyte[] data, int width, int height);
    void beginScene();
    void endScene();
    void postProcessScene();

    void initializeDrawableResources();
    void bindDrawableVao();
    void createDrawableBuffers(out uint vbo, out uint ibo, out uint dbo);
    void uploadDrawableIndices(uint ibo, ushort[] indices);
    void uploadDrawableVertices(uint vbo, vec2[] vertices);
    void uploadDrawableDeform(uint dbo, vec2[] deform);
    void drawDrawableElements(uint ibo, size_t indexCount);

    uint createPartUvBuffer();
    void updatePartUvBuffer(uint buffer, ref MeshData data);

    bool supportsAdvancedBlend();
    bool supportsAdvancedBlendCoherent();
    void setAdvancedBlendCoherent(bool enabled);
    void setLegacyBlendMode(BlendMode mode);
    void setAdvancedBlendEquation(BlendMode mode);
    void issueBlendBarrier();
    void initDebugRenderer();
    void setDebugPointSize(float size);
    void setDebugLineWidth(float size);
    void uploadDebugBuffer(vec3[] points, ushort[] indices);
    void setDebugExternalBuffer(uint vbo, uint ibo, int count);
    void drawDebugPoints(vec4 color, mat4 mvp);
    void drawDebugLines(vec4 color, mat4 mvp);

    void drawPartPacket(ref PartDrawPacket packet);
    void drawMaskPacket(ref MaskDrawPacket packet);
    void beginDynamicComposite(DynamicComposite composite);
    void endDynamicComposite(DynamicComposite composite);
    void destroyDynamicComposite(DynamicComposite composite);
    void beginMask(bool useStencil);
    void applyMask(ref MaskApplyPacket packet);
    void beginMaskContent();
    void endMask();
    void beginComposite();
    void drawCompositeQuad(ref CompositeDrawPacket packet);
    void endComposite();
    void drawTextureAtPart(Texture texture, Part part);
    void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                                vec3 color, vec3 screenColor);
    void drawTextureAtRect(Texture texture, rect area, rect uvs,
                            float opacity, vec3 color, vec3 screenColor,
                            Shader shader = null, Camera cam = null);
    uint framebufferHandle();
    uint renderImageHandle();
    uint compositeFramebufferHandle();
    uint compositeImageHandle();
    uint mainAlbedoHandle();
    uint mainEmissiveHandle();
    uint mainBumpHandle();
    uint compositeEmissiveHandle();
    uint compositeBumpHandle();
    uint blendFramebufferHandle();
    uint blendAlbedoHandle();
    uint blendEmissiveHandle();
    uint blendBumpHandle();
    void addBasicLightingPostProcess();
    void setDifferenceAggregationEnabled(bool enabled);
    bool isDifferenceAggregationEnabled();
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region);
    DifferenceEvaluationRegion getDifferenceAggregationRegion();
    bool evaluateDifferenceAggregation(uint texture, int width, int height);
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result);

    // Shader management
    RenderShaderHandle createShader(string vertexSource, string fragmentSource);
    void destroyShader(RenderShaderHandle shader);
    void useShader(RenderShaderHandle shader);
    int getShaderUniformLocation(RenderShaderHandle shader, string name);
    void setShaderUniform(RenderShaderHandle shader, int location, bool value);
    void setShaderUniform(RenderShaderHandle shader, int location, int value);
    void setShaderUniform(RenderShaderHandle shader, int location, float value);
    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value);
    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value);
    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value);
    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value);

    // Texture management
    RenderTextureHandle createTextureHandle();
    void destroyTextureHandle(RenderTextureHandle texture);
    void bindTextureHandle(RenderTextureHandle texture, uint unit);
    void uploadTextureData(RenderTextureHandle texture, int width, int height, int inChannels,
                           int outChannels, bool stencil, ubyte[] data);
    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width, int height,
                             int channels, ubyte[] data);
    void generateTextureMipmap(RenderTextureHandle texture);
    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering);
    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping);
    void applyTextureAnisotropy(RenderTextureHandle texture, float value);
    float maxTextureAnisotropy();
    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                         ubyte[] buffer);
    size_t textureNativeHandle(RenderTextureHandle texture);
}
