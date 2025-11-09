module nijilive.core.render.backends.opengl;

import nijilive.core.render.backends;
import nijilive.core.render.commands : PartDrawPacket, CompositeDrawPacket, MaskApplyPacket,
    MaskDrawPacket;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.runtime_state : registerRenderBackend;
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
import nijilive.math : vec2, vec3, vec4, rect, mat4;
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

class GLRenderBackend : RenderBackend {
    override void initializeRenderer() {
        oglInitRenderer();
        oglInitDrawableBackend();
        oglInitPartBackendResources();
        oglInitMaskBackend();
    }

    override void resizeViewportTargets(int width, int height) {
        oglResizeViewport(width, height);
    }

    override void dumpViewport(ref ubyte[] data, int width, int height) {
        oglDumpViewport(data, width, height);
    }

    override void beginScene() {
        oglBeginScene();
    }

    override void endScene() {
        oglEndScene();
    }

    override void postProcessScene() {
        oglPostProcessScene();
    }

    override void initializeDrawableResources() {
        oglInitDrawableBackend();
    }

    override void bindDrawableVao() {
        oglBindDrawableVao();
    }

    override void createDrawableBuffers(out uint vbo, out uint ibo, out uint dbo) {
        oglCreateDrawableBuffers(vbo, ibo, dbo);
    }

    override void uploadDrawableIndices(uint ibo, ushort[] indices) {
        oglUploadDrawableIndices(ibo, indices);
    }

    override void uploadDrawableVertices(uint vbo, vec2[] vertices) {
        oglUploadDrawableVertices(vbo, vertices);
    }

    override void uploadDrawableDeform(uint dbo, vec2[] deform) {
        oglUploadDrawableDeform(dbo, deform);
    }

    override void drawDrawableElements(uint ibo, size_t indexCount) {
        oglDrawDrawableElements(ibo, indexCount);
    }

    override uint createPartUvBuffer() {
        return oglCreatePartUvBuffer();
    }

    override void updatePartUvBuffer(uint buffer, ref MeshData data) {
        oglUpdatePartUvBuffer(buffer, data);
    }

    override bool supportsAdvancedBlend() {
        return oglSupportsAdvancedBlend();
    }

    override bool supportsAdvancedBlendCoherent() {
        return oglSupportsAdvancedBlendCoherent();
    }

    override void setAdvancedBlendCoherent(bool enabled) {
        oglSetAdvancedBlendCoherent(enabled);
    }

    override void setLegacyBlendMode(BlendMode mode) {
        oglSetLegacyBlendMode(mode);
    }

    override void setAdvancedBlendEquation(BlendMode mode) {
        oglSetAdvancedBlendEquation(mode);
    }

    override void issueBlendBarrier() {
        oglIssueBlendBarrier();
    }

    override void initDebugRenderer() {
        oglInitDebugRenderer();
    }

    override void setDebugPointSize(float size) {
        oglSetDebugPointSize(size);
    }

    override void setDebugLineWidth(float size) {
        oglSetDebugLineWidth(size);
    }

    override void uploadDebugBuffer(vec3[] points, ushort[] indices) {
        oglUploadDebugBuffer(points, indices);
    }

    override void setDebugExternalBuffer(uint vbo, uint ibo, int count) {
        oglSetDebugExternalBuffer(vbo, ibo, count);
    }

    override void drawDebugPoints(vec4 color, mat4 mvp) {
        oglDrawDebugPoints(color, mvp);
    }

    override void drawDebugLines(vec4 color, mat4 mvp) {
        oglDrawDebugLines(color, mvp);
    }

    override void drawPartPacket(ref PartDrawPacket packet) {
        oglDrawPartPacket(packet);
    }

    override void drawMaskPacket(ref MaskDrawPacket packet) {
        oglExecuteMaskPacket(packet);
    }

    override void beginDynamicComposite(DynamicComposite composite) {
        oglBeginDynamicComposite(composite);
    }

    override void endDynamicComposite(DynamicComposite composite) {
        oglEndDynamicComposite(composite);
    }

    override void destroyDynamicComposite(DynamicComposite composite) {
        oglDestroyDynamicComposite(composite);
    }

    override void beginMask(bool useStencil) {
        oglBeginMask(useStencil);
    }

    override void applyMask(ref MaskApplyPacket packet) {
        oglExecuteMaskApplyPacket(packet);
    }

    override void beginMaskContent() {
        oglBeginMaskContent();
    }

    override void endMask() {
        oglEndMask();
    }
    override void beginComposite() {
        oglBeginComposite();
    }

    override void drawCompositeQuad(ref CompositeDrawPacket packet) {
        oglDrawCompositeQuad(packet);
    }

    override void endComposite() {
        oglEndComposite();
    }

    override void drawTextureAtPart(Texture texture, Part part) {
        oglDrawTextureAtPart(texture, part);
    }

    override void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                                        vec3 color, vec3 screenColor) {
        oglDrawTextureAtPosition(texture, position, opacity, color, screenColor);
    }

    override void drawTextureAtRect(Texture texture, rect area, rect uvs,
                                    float opacity, vec3 color, vec3 screenColor,
                                    Shader shader = null, Camera cam = null) {
        oglDrawTextureAtRect(texture, area, uvs, opacity, color, screenColor, shader, cam);
    }

    override uint framebufferHandle() {
        return oglGetFramebuffer();
    }

    override uint renderImageHandle() {
        return oglGetRenderImage();
    }

    override uint compositeFramebufferHandle() {
        return oglGetCompositeFramebuffer();
    }

    override uint compositeImageHandle() {
        return oglGetCompositeImage();
    }

    override uint mainAlbedoHandle() {
        return oglGetMainAlbedo();
    }

    override uint mainEmissiveHandle() {
        return oglGetMainEmissive();
    }

    override uint mainBumpHandle() {
        return oglGetMainBump();
    }

    override uint compositeEmissiveHandle() {
        return oglGetCompositeEmissive();
    }

    override uint compositeBumpHandle() {
        return oglGetCompositeBump();
    }

    override uint blendFramebufferHandle() {
        return oglGetBlendFramebuffer();
    }

    override uint blendAlbedoHandle() {
        return oglGetBlendAlbedo();
    }

    override uint blendEmissiveHandle() {
        return oglGetBlendEmissive();
    }

    override uint blendBumpHandle() {
        return oglGetBlendBump();
    }

    override void addBasicLightingPostProcess() {
        oglAddBasicLightingPostProcess();
    }

    override void setDifferenceAggregationEnabled(bool enabled) {
        oglSetDifferenceAggregationEnabled(enabled);
    }

    override bool isDifferenceAggregationEnabled() {
        return oglIsDifferenceAggregationEnabled();
    }

    override void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) {
        oglSetDifferenceAggregationRegion(region);
    }

    override DifferenceEvaluationRegion getDifferenceAggregationRegion() {
        return oglGetDifferenceAggregationRegion();
    }

    override bool evaluateDifferenceAggregation(uint texture, int width, int height) {
        return oglEvaluateDifferenceAggregation(texture, width, height);
    }

    override bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        return oglFetchDifferenceAggregationResult(result);
    }
}

shared static this() {
    registerRenderBackend(new GLRenderBackend());
}
