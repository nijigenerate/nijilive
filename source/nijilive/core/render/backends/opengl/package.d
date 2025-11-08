module nijilive.core.render.backends.opengl;

import nijilive.core.render.backends;
import nijilive.core.render.commands : PartDrawPacket, CompositeDrawPacket, MaskApplyPacket,
    MaskDrawPacket;
import nijilive.core.nodes : Node;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.runtime_state : registerRenderBackend;
import nijilive.core.render.backends.opengl.runtime :
    initRendererOpenGL,
    resizeViewportOpenGL,
    dumpViewportOpenGL,
    inBeginScene,
    inEndScene,
    inPostProcessScene,
    inPostProcessingAddBasicLighting,
    inBeginComposite,
    inEndComposite,
    inGetFramebuffer,
    inGetRenderImage,
    inGetCompositeFramebuffer,
    inGetCompositeImage,
    inGetMainAlbedo,
    inGetMainEmissive,
    inGetMainBump,
    inGetCompositeEmissive,
    inGetCompositeBump,
    inGetBlendFramebuffer,
    inGetBlendAlbedo,
    inGetBlendEmissive,
    inGetBlendBump;
import nijilive.core.render.backends.opengl.debug_renderer :
    initDebugRendererGL,
    setDebugPointSizeGL,
    setDebugLineWidthGL,
    uploadDebugBufferGL,
    setDebugExternalBufferGL,
    drawDebugPointsGL,
    drawDebugLinesGL;
import nijilive.core.render.backends.opengl.diff_collect_impl :
    setDifferenceAggregationEnabledGL,
    isDifferenceAggregationEnabledGL,
    setDifferenceAggregationRegionGL,
    getDifferenceAggregationRegionGL,
    evaluateDifferenceAggregationGL,
    fetchDifferenceAggregationResultGL;
import nijilive.math : vec2, vec3, vec4, rect, mat4;
import nijilive.core.meshdata : MeshData;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
import nijilive.math.camera : Camera;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
import nijilive.core.render.backends.opengl.part : glDrawPartPacket;
import nijilive.core.render.backends.opengl.composite : compositeDrawQuad;
import nijilive.core.render.backends.opengl.mask : executeMaskApplyPacket, executeMaskPacket;
import nijilive.core.render.backends.opengl.dynamic_composite : beginDynamicCompositeGL,
    endDynamicCompositeGL, destroyDynamicCompositeGL;
import nijilive.core.render.backends.opengl.drawable_buffers : initDrawableBackend,
    bindDrawableVAO,
    glCreateDrawableBuffers = createDrawableBuffers,
    glUploadDrawableIndices = uploadDrawableIndices,
    glUploadDrawableVertices = uploadDrawableVertices,
    glUploadDrawableDeform = uploadDrawableDeform,
    glDrawDrawableElements = drawDrawableElements;
import nijilive.core.render.backends.opengl.part_resources :
    initPartBackendResources, createPartUVBuffer, updatePartUVBuffer;
import nijilive.core.render.backends.opengl.mask_resources : initMaskBackendResources;
import nijilive.core.render.backends.opengl.blend_state :
    glSetAdvancedBlendCoherent = setAdvancedBlendCoherent,
    glSetLegacyBlendMode = setLegacyBlendMode,
    glSetAdvancedBlendEquation = setAdvancedBlendEquation,
    glIssueBlendBarrier = issueBlendBarrier,
    hasAdvancedBlendSupport, hasAdvancedBlendCoherentSupport;
import nijilive.core.render.backends.opengl.draw_texture :
    inDrawTextureAtPart, inDrawTextureAtPosition, inDrawTextureAtRect;
import nijilive.core.render.backends.opengl.mask_state : beginMaskGL, endMaskGL, beginMaskContentGL;

class GLRenderBackend : RenderBackend {
    override void initializeRenderer() {
        initRendererOpenGL();
        initDrawableBackend();
        initPartBackendResources();
        initMaskBackendResources();
    }

    override void resizeViewportTargets(int width, int height) {
        resizeViewportOpenGL(width, height);
    }

    override void dumpViewport(ref ubyte[] data, int width, int height) {
        dumpViewportOpenGL(data, width, height);
    }

    override void beginScene() {
        inBeginScene();
    }

    override void endScene() {
        inEndScene();
    }

    override void postProcessScene() {
        inPostProcessScene();
    }

    override void initializeDrawableResources() {
        initDrawableBackend();
    }

    override void bindDrawableVao() {
        bindDrawableVAO();
    }

    override void createDrawableBuffers(out uint vbo, out uint ibo, out uint dbo) {
        glCreateDrawableBuffers(vbo, ibo, dbo);
    }

    override void uploadDrawableIndices(uint ibo, ushort[] indices) {
        glUploadDrawableIndices(ibo, indices);
    }

    override void uploadDrawableVertices(uint vbo, vec2[] vertices) {
        glUploadDrawableVertices(vbo, vertices);
    }

    override void uploadDrawableDeform(uint dbo, vec2[] deform) {
        glUploadDrawableDeform(dbo, deform);
    }

    override void drawDrawableElements(uint ibo, size_t indexCount) {
        glDrawDrawableElements(ibo, indexCount);
    }

    override uint createPartUvBuffer() {
        return createPartUVBuffer();
    }

    override void updatePartUvBuffer(uint buffer, ref MeshData data) {
        updatePartUVBuffer(buffer, data);
    }

    override bool supportsAdvancedBlend() {
        return hasAdvancedBlendSupport();
    }

    override bool supportsAdvancedBlendCoherent() {
        return hasAdvancedBlendCoherentSupport();
    }

    override void setAdvancedBlendCoherent(bool enabled) {
        glSetAdvancedBlendCoherent(enabled);
    }

    override void setLegacyBlendMode(BlendMode mode) {
        glSetLegacyBlendMode(mode);
    }

    override void setAdvancedBlendEquation(BlendMode mode) {
        glSetAdvancedBlendEquation(mode);
    }

    override void issueBlendBarrier() {
        glIssueBlendBarrier();
    }

    override void initDebugRenderer() {
        initDebugRendererGL();
    }

    override void setDebugPointSize(float size) {
        setDebugPointSizeGL(size);
    }

    override void setDebugLineWidth(float size) {
        setDebugLineWidthGL(size);
    }

    override void uploadDebugBuffer(vec3[] points, ushort[] indices) {
        uploadDebugBufferGL(points, indices);
    }

    override void setDebugExternalBuffer(uint vbo, uint ibo, int count) {
        setDebugExternalBufferGL(vbo, ibo, count);
    }

    override void drawDebugPoints(vec4 color, mat4 mvp) {
        drawDebugPointsGL(color, mvp);
    }

    override void drawDebugLines(vec4 color, mat4 mvp) {
        drawDebugLinesGL(color, mvp);
    }

    override void drawNode(Node node) {
        if (node is null) return;
        node.drawOne();
    }

    override void drawPartPacket(ref PartDrawPacket packet) {
        glDrawPartPacket(packet);
    }

    override void drawMaskPacket(ref MaskDrawPacket packet) {
        executeMaskPacket(packet);
    }

    override void beginDynamicComposite(DynamicComposite composite) {
        beginDynamicCompositeGL(composite);
    }

    override void endDynamicComposite(DynamicComposite composite) {
        endDynamicCompositeGL(composite);
    }

    override void destroyDynamicComposite(DynamicComposite composite) {
        destroyDynamicCompositeGL(composite);
    }

    override void beginMask(bool useStencil) {
        beginMaskGL(useStencil);
    }

    override void applyMask(ref MaskApplyPacket packet) {
        executeMaskApplyPacket(packet);
    }

    override void beginMaskContent() {
        beginMaskContentGL();
    }

    override void endMask() {
        endMaskGL();
    }
    override void beginComposite() {
        inBeginComposite();
    }

    override void drawCompositeQuad(ref CompositeDrawPacket packet) {
        compositeDrawQuad(packet);
    }

    override void endComposite() {
        inEndComposite();
    }

    override void drawTextureAtPart(Texture texture, Part part) {
        inDrawTextureAtPart(texture, part);
    }

    override void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                                        vec3 color, vec3 screenColor) {
        inDrawTextureAtPosition(texture, position, opacity, color, screenColor);
    }

    override void drawTextureAtRect(Texture texture, rect area, rect uvs,
                                    float opacity, vec3 color, vec3 screenColor,
                                    Shader shader = null, Camera cam = null) {
        inDrawTextureAtRect(texture, area, uvs, opacity, color, screenColor, shader, cam);
    }

    override uint framebufferHandle() {
        return inGetFramebuffer();
    }

    override uint renderImageHandle() {
        return inGetRenderImage();
    }

    override uint compositeFramebufferHandle() {
        return inGetCompositeFramebuffer();
    }

    override uint compositeImageHandle() {
        return inGetCompositeImage();
    }

    override uint mainAlbedoHandle() {
        return inGetMainAlbedo();
    }

    override uint mainEmissiveHandle() {
        return inGetMainEmissive();
    }

    override uint mainBumpHandle() {
        return inGetMainBump();
    }

    override uint compositeEmissiveHandle() {
        return inGetCompositeEmissive();
    }

    override uint compositeBumpHandle() {
        return inGetCompositeBump();
    }

    override uint blendFramebufferHandle() {
        return inGetBlendFramebuffer();
    }

    override uint blendAlbedoHandle() {
        return inGetBlendAlbedo();
    }

    override uint blendEmissiveHandle() {
        return inGetBlendEmissive();
    }

    override uint blendBumpHandle() {
        return inGetBlendBump();
    }

    override void addBasicLightingPostProcess() {
        inPostProcessingAddBasicLighting();
    }

    override void setDifferenceAggregationEnabled(bool enabled) {
        setDifferenceAggregationEnabledGL(enabled);
    }

    override bool isDifferenceAggregationEnabled() {
        return isDifferenceAggregationEnabledGL();
    }

    override void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) {
        setDifferenceAggregationRegionGL(region);
    }

    override DifferenceEvaluationRegion getDifferenceAggregationRegion() {
        return getDifferenceAggregationRegionGL();
    }

    override bool evaluateDifferenceAggregation(uint texture, int width, int height) {
        return evaluateDifferenceAggregationGL(texture, width, height);
    }

    override bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        return fetchDifferenceAggregationResultGL(result);
    }
}

shared static this() {
    registerRenderBackend(new GLRenderBackend());
}
