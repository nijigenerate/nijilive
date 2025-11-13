module nijilive.core.render.backends.opengl;

version (InDoesRender) {

import nijilive.core.render.backends;
import nijilive.core.render.commands : PartDrawPacket, CompositeDrawPacket, MaskApplyPacket,
    MaskDrawPacket, DynamicCompositePass, DynamicCompositeSurface;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.render.backends.opengl.runtime :
    oglInitRenderer,
    oglResizeViewport,
    oglDumpViewport,
    oglBeginScene,
    oglEndScene,
    oglPostProcessScene,
    oglAddBasicLightingPostProcess,
    oglBeginComposite,
    oglEndComposite,
    oglGetFramebuffer,
    oglGetRenderImage,
    oglGetCompositeFramebuffer,
    oglGetCompositeImage,
    oglGetMainAlbedo,
    oglGetMainEmissive,
    oglGetMainBump,
    oglGetCompositeEmissive,
    oglGetCompositeBump,
    oglGetBlendFramebuffer,
    oglGetBlendAlbedo,
    oglGetBlendEmissive,
    oglGetBlendBump;
import nijilive.core.render.backends.opengl.debug_renderer :
    oglInitDebugRenderer,
    oglSetDebugPointSize,
    oglSetDebugLineWidth,
    oglUploadDebugBuffer,
    oglSetDebugExternalBuffer,
    oglDrawDebugPoints,
    oglDrawDebugLines;
import nijilive.core.render.backends.opengl.diff_collect_impl :
    oglSetDifferenceAggregationEnabled,
    oglIsDifferenceAggregationEnabled,
    oglSetDifferenceAggregationRegion,
    oglGetDifferenceAggregationRegion,
    oglEvaluateDifferenceAggregation,
    oglFetchDifferenceAggregationResult;
import nijilive.math : vec2, vec3, vec4, rect, mat4, Vec2Array, Vec3Array;
import nijilive.core.meshdata : MeshData;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
import nijilive.math.camera : Camera;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
import nijilive.core.render.backends.opengl.part :
    oglDrawPartPacket,
    oglInitPartBackendResources,
    oglCreatePartUvBuffer,
    oglUpdatePartUvBuffer;
import nijilive.core.render.backends.opengl.composite : oglDrawCompositeQuad;
import nijilive.core.render.backends.opengl.mask :
    oglExecuteMaskApplyPacket,
    oglExecuteMaskPacket,
    oglBeginMask,
    oglEndMask,
    oglBeginMaskContent,
    oglInitMaskBackend;
import nijilive.core.render.backends.opengl.dynamic_composite :
    oglBeginDynamicComposite,
    oglEndDynamicComposite,
    oglDestroyDynamicComposite;
import nijilive.core.render.backends.opengl.drawable_buffers :
    oglInitDrawableBackend,
    oglBindDrawableVao,
    oglCreateDrawableBuffers,
    oglUploadDrawableIndices,
    oglUploadDrawableVertices,
    oglUploadDrawableDeform,
    oglDrawDrawableElements;
import nijilive.core.render.backends.opengl.blend :
    oglSetAdvancedBlendCoherent,
    oglSetLegacyBlendMode,
    oglSetAdvancedBlendEquation,
    oglIssueBlendBarrier,
    oglSupportsAdvancedBlend,
    oglSupportsAdvancedBlendCoherent,
    oglGetBlendShader,
    oglBlendToBuffer;
import nijilive.core.render.backends.opengl.draw_texture :
    oglDrawTextureAtPart, oglDrawTextureAtPosition, oglDrawTextureAtRect;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.core.render.backends.opengl.shader_backend :
    ShaderProgramHandle,
    oglCreateShaderProgram,
    oglDestroyShaderProgram,
    oglUseShaderProgram,
    oglShaderGetUniformLocation,
    oglSetUniformBool,
    oglSetUniformInt,
    oglSetUniformFloat,
    oglSetUniformVec2,
    oglSetUniformVec3,
    oglSetUniformVec4,
    oglSetUniformMat4;
import nijilive.core.render.backends.opengl.texture_backend :
    oglCreateTextureHandle,
    oglDeleteTextureHandle,
    oglBindTextureHandle,
    oglUploadTextureData,
    oglUpdateTextureRegion,
    oglGenerateTextureMipmap,
    oglApplyTextureFiltering,
    oglApplyTextureWrapping,
    oglApplyTextureAnisotropy,
    oglMaxTextureAnisotropy,
    oglReadTextureData;
import nijilive.core.render.backends.opengl.handles :
    GLShaderHandle,
    GLTextureHandle,
    requireGLShader,
    requireGLTexture;

class RenderingBackend(BackendEnum backendType : BackendEnum.OpenGL) {
    void initializeRenderer() {
        oglInitRenderer();
        oglInitDrawableBackend();
        oglInitPartBackendResources();
        oglInitMaskBackend();
    }

    void resizeViewportTargets(int width, int height) {
        oglResizeViewport(width, height);
    }

    void dumpViewport(ref ubyte[] data, int width, int height) {
        oglDumpViewport(data, width, height);
    }

    void beginScene() {
        oglBeginScene();
    }

    void endScene() {
        oglEndScene();
    }

    void postProcessScene() {
        oglPostProcessScene();
    }

    void initializeDrawableResources() {
        oglInitDrawableBackend();
    }

    void bindDrawableVao() {
        oglBindDrawableVao();
    }

    void createDrawableBuffers(out uint vbo, out uint ibo, out uint dbo) {
        oglCreateDrawableBuffers(vbo, ibo, dbo);
    }

    void uploadDrawableIndices(uint ibo, ushort[] indices) {
        oglUploadDrawableIndices(ibo, indices);
    }

    void uploadDrawableVertices(uint vbo, Vec2Array vertices) {
        oglUploadDrawableVertices(vbo, vertices);
    }

    void uploadDrawableDeform(uint dbo, Vec2Array deform) {
        oglUploadDrawableDeform(dbo, deform);
    }

    void drawDrawableElements(uint ibo, size_t indexCount) {
        oglDrawDrawableElements(ibo, indexCount);
    }

    uint createPartUvBuffer() {
        return oglCreatePartUvBuffer();
    }

    void updatePartUvBuffer(uint buffer, ref MeshData data) {
        oglUpdatePartUvBuffer(buffer, data);
    }

    bool supportsAdvancedBlend() {
        return oglSupportsAdvancedBlend();
    }

    bool supportsAdvancedBlendCoherent() {
        return oglSupportsAdvancedBlendCoherent();
    }

    void setAdvancedBlendCoherent(bool enabled) {
        oglSetAdvancedBlendCoherent(enabled);
    }

    void setLegacyBlendMode(BlendMode mode) {
        oglSetLegacyBlendMode(mode);
    }

    void setAdvancedBlendEquation(BlendMode mode) {
        oglSetAdvancedBlendEquation(mode);
    }

    void issueBlendBarrier() {
        oglIssueBlendBarrier();
    }

    void initDebugRenderer() {
        oglInitDebugRenderer();
    }

    void setDebugPointSize(float size) {
        oglSetDebugPointSize(size);
    }

    void setDebugLineWidth(float size) {
        oglSetDebugLineWidth(size);
    }

    void uploadDebugBuffer(Vec3Array points, ushort[] indices) {
        oglUploadDebugBuffer(points, indices);
    }

    void setDebugExternalBuffer(uint vbo, uint ibo, int count) {
        oglSetDebugExternalBuffer(vbo, ibo, count);
    }

    void drawDebugPoints(vec4 color, mat4 mvp) {
        oglDrawDebugPoints(color, mvp);
    }

    void drawDebugLines(vec4 color, mat4 mvp) {
        oglDrawDebugLines(color, mvp);
    }

    void drawPartPacket(ref PartDrawPacket packet) {
        oglDrawPartPacket(packet);
    }

    void drawMaskPacket(ref MaskDrawPacket packet) {
        oglExecuteMaskPacket(packet);
    }

    void beginDynamicComposite(DynamicCompositePass pass) {
        oglBeginDynamicComposite(pass);
    }

    void endDynamicComposite(DynamicCompositePass pass) {
        oglEndDynamicComposite(pass);
    }

    void destroyDynamicComposite(DynamicCompositeSurface surface) {
        oglDestroyDynamicComposite(surface);
    }

    void beginMask(bool useStencil) {
        oglBeginMask(useStencil);
    }

    void applyMask(ref MaskApplyPacket packet) {
        oglExecuteMaskApplyPacket(packet);
    }

    void beginMaskContent() {
        oglBeginMaskContent();
    }

    void endMask() {
        oglEndMask();
    }
    void beginComposite() {
        oglBeginComposite();
    }

    void drawCompositeQuad(ref CompositeDrawPacket packet) {
        oglDrawCompositeQuad(packet);
    }

    void endComposite() {
        oglEndComposite();
    }

    void drawTextureAtPart(Texture texture, Part part) {
        oglDrawTextureAtPart(texture, part);
    }

    void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                                        vec3 color, vec3 screenColor) {
        oglDrawTextureAtPosition(texture, position, opacity, color, screenColor);
    }

    void drawTextureAtRect(Texture texture, rect area, rect uvs,
                                    float opacity, vec3 color, vec3 screenColor,
                                    Shader shader = null, Camera cam = null) {
        oglDrawTextureAtRect(texture, area, uvs, opacity, color, screenColor, shader, cam);
    }

    uint framebufferHandle() {
        return oglGetFramebuffer();
    }

    uint renderImageHandle() {
        return oglGetRenderImage();
    }

    uint compositeFramebufferHandle() {
        return oglGetCompositeFramebuffer();
    }

    uint compositeImageHandle() {
        return oglGetCompositeImage();
    }

    uint mainAlbedoHandle() {
        return oglGetMainAlbedo();
    }

    uint mainEmissiveHandle() {
        return oglGetMainEmissive();
    }

    uint mainBumpHandle() {
        return oglGetMainBump();
    }

    uint compositeEmissiveHandle() {
        return oglGetCompositeEmissive();
    }

    uint compositeBumpHandle() {
        return oglGetCompositeBump();
    }

    uint blendFramebufferHandle() {
        return oglGetBlendFramebuffer();
    }

    uint blendAlbedoHandle() {
        return oglGetBlendAlbedo();
    }

    uint blendEmissiveHandle() {
        return oglGetBlendEmissive();
    }

    uint blendBumpHandle() {
        return oglGetBlendBump();
    }

    void addBasicLightingPostProcess() {
        oglAddBasicLightingPostProcess();
    }

    void setDifferenceAggregationEnabled(bool enabled) {
        oglSetDifferenceAggregationEnabled(enabled);
    }

    bool isDifferenceAggregationEnabled() {
        return oglIsDifferenceAggregationEnabled();
    }

    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) {
        oglSetDifferenceAggregationRegion(region);
    }

    DifferenceEvaluationRegion getDifferenceAggregationRegion() {
        return oglGetDifferenceAggregationRegion();
    }

    bool evaluateDifferenceAggregation(uint texture, int width, int height) {
        return oglEvaluateDifferenceAggregation(texture, width, height);
    }

    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        return oglFetchDifferenceAggregationResult(result);
    }

    RenderShaderHandle createShader(string vertexSource, string fragmentSource) {
        auto handle = new GLShaderHandle();
        oglCreateShaderProgram(handle.shader, vertexSource, fragmentSource);
        return handle;
    }

    void destroyShader(RenderShaderHandle shader) {
        auto handle = requireGLShader(shader);
        oglDestroyShaderProgram(handle.shader);
        handle.shader = ShaderProgramHandle.init;
    }

    void useShader(RenderShaderHandle shader) {
        auto handle = requireGLShader(shader);
        oglUseShaderProgram(handle.shader);
    }

    int getShaderUniformLocation(RenderShaderHandle shader, string name) {
        auto handle = requireGLShader(shader);
        return oglShaderGetUniformLocation(handle.shader, name);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, bool value) {
        requireGLShader(shader);
        oglSetUniformBool(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, int value) {
        requireGLShader(shader);
        oglSetUniformInt(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, float value) {
        requireGLShader(shader);
        oglSetUniformFloat(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value) {
        requireGLShader(shader);
        oglSetUniformVec2(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value) {
        requireGLShader(shader);
        oglSetUniformVec3(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value) {
        requireGLShader(shader);
        oglSetUniformVec4(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value) {
        requireGLShader(shader);
        oglSetUniformMat4(location, value);
    }

    RenderTextureHandle createTextureHandle() {
        auto handle = new GLTextureHandle();
        oglCreateTextureHandle(handle.id);
        return handle;
    }

    void destroyTextureHandle(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        oglDeleteTextureHandle(handle.id);
        handle.id = 0;
    }

    void bindTextureHandle(RenderTextureHandle texture, uint unit) {
        auto handle = requireGLTexture(texture);
        oglBindTextureHandle(handle.id, unit);
    }

    void uploadTextureData(RenderTextureHandle texture, int width, int height,
                                    int inChannels, int outChannels, bool stencil,
                                    ubyte[] data) {
        auto handle = requireGLTexture(texture);
        oglUploadTextureData(handle.id, width, height, inChannels, outChannels, stencil, data);
    }

    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width,
                                      int height, int channels, ubyte[] data) {
        auto handle = requireGLTexture(texture);
        oglUpdateTextureRegion(handle.id, x, y, width, height, channels, data);
    }

    void generateTextureMipmap(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        oglGenerateTextureMipmap(handle.id);
    }

    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering) {
        auto handle = requireGLTexture(texture);
        oglApplyTextureFiltering(handle.id, filtering);
    }

    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto handle = requireGLTexture(texture);
        oglApplyTextureWrapping(handle.id, wrapping);
    }

    void applyTextureAnisotropy(RenderTextureHandle texture, float value) {
        auto handle = requireGLTexture(texture);
        oglApplyTextureAnisotropy(handle.id, value);
    }

    float maxTextureAnisotropy() {
        return oglMaxTextureAnisotropy();
    }

    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                                  ubyte[] buffer) {
        auto handle = requireGLTexture(texture);
        oglReadTextureData(handle.id, channels, stencil, buffer);
    }

    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        return handle.id;
    }
}

}
