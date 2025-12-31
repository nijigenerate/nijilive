module nijilive.core.render.backends.vulkan;

import std.exception : enforce;
import std.string : toStringz, strip;
import std.algorithm : endsWith;

import erupted;
import erupted.functions;
import erupted.vulkan_lib_loader;
import erupted.types;
alias VkInstance = erupted.types.VkInstance;
alias VkPhysicalDevice = erupted.types.VkPhysicalDevice;
alias VkDevice = erupted.types.VkDevice;
alias VkQueue = erupted.types.VkQueue;
alias VkSurfaceKHR = erupted.types.VkSurfaceKHR;
alias VkSwapchainKHR = erupted.types.VkSwapchainKHR;
alias VkImage = erupted.types.VkImage;
alias VkImageView = erupted.types.VkImageView;
alias VkRenderPass = erupted.types.VkRenderPass;
alias VkFramebuffer = erupted.types.VkFramebuffer;
alias VkPipelineLayout = erupted.types.VkPipelineLayout;
alias VkPipeline = erupted.types.VkPipeline;
alias VkDescriptorSetLayout = erupted.types.VkDescriptorSetLayout;
alias VkDescriptorPool = erupted.types.VkDescriptorPool;
alias VkDescriptorSet = erupted.types.VkDescriptorSet;
alias VkCommandBuffer = erupted.types.VkCommandBuffer;
alias VkSampler = erupted.types.VkSampler;

import nijilive.core.render.backends;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.render.commands : PartDrawPacket, MaskApplyPacket,
    MaskDrawPacket, MaskDrawableKind, DynamicCompositeSurface, DynamicCompositePass;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.math : vec2, vec3, vec4, mat4, Vec2Array, Vec3Array, rect;
import nijilive.math.camera : Camera;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
import nijilive.core.runtime_state : inGetCamera;

enum maxFramesInFlight = 2;

struct GpuImage {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkFormat format;
    uint mipLevels;
    VkExtent2D extent;
    VkImageAspectFlags aspect;
}

/// Simple Vulkan-backed handle placeholders.
class VkShaderHandle : RenderShaderHandle {
    size_t id;
    VkShaderModule vert;
    VkShaderModule frag;
    string vertEntry = "main";
    string fragEntry = "main";
}

class VkTextureHandle : RenderTextureHandle {
    size_t id;
    uint width;
    uint height;
    uint mipLevels = 1;
    GpuImage image;
    VkSampler sampler;
    Filtering filtering = Filtering.Linear;
    Wrapping wrapping = Wrapping.Clamp;
    float anisotropy = 1.0f;
}

/// Vulkan backend skeleton. All operations currently stubbed out and will throw
/// until a full implementation is added.
class RenderingBackend(BackendEnum backendType : BackendEnum.Vulkan) {
private:
    /// Minimal context for bring-up. Extend with swapchain/renderpass/etc.
    VkInstance instance;
    VkPhysicalDevice physicalDevice;
    VkDevice device;
    VkQueue graphicsQueue;
    VkQueue presentQueue;
    uint graphicsQueueFamily;
    uint presentQueueFamily;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat swapFormat;
    VkExtent2D swapExtent;
    VkImage[] swapImages;
    VkImageView[] swapImageViews;
    VkRenderPass renderPass;
    VkFramebuffer[] swapFramebuffers;
    VkRenderPass offscreenRenderPass;
    VkRenderPass offscreenRenderPassLoad;
    VkFramebuffer offscreenFramebuffer;
    VkPipelineLayout pipelineLayout;
    VkPipeline basicPipeline;
    VkPipeline maskPipeline;
    VkPipeline compositePipeline;
    VkPipeline basicMaskedPipeline;
    VkPipeline compositeMaskedPipeline;
    VkDescriptorSetLayout descriptorSetLayout;
    VkDescriptorPool descriptorPool;
    VkDescriptorSet descriptorSet;
    Buffer globalsUbo;
    Buffer paramsUbo;
    struct GlobalsData {
        mat4 mvp;
        vec2 offset;
    }
    struct ParamsData {
        float opacity;
        vec3 multColor;
        vec3 screenColor;
        float emissionStrength;
    }
    uint currentImageIndex;
    uint currentFrame;
    VkCommandBuffer activeCommand;
    VkPhysicalDeviceFeatures deviceFeatures;
    VkPhysicalDeviceProperties deviceProperties;
    bool supportsAnisotropy;
    float maxSupportedAnisotropy;
    string glslcPath;
    struct DynamicCompositeState {
        VkFramebuffer framebuffer;
        VkExtent2D extent;
    }
    struct Buffer {
        VkBuffer buffer;
        VkDeviceMemory memory;
        size_t size;
    }
    Buffer sharedVertexBuffer;
    Buffer sharedUvBuffer;
    Buffer sharedDeformBuffer;
    Buffer[RenderResourceHandle] indexBuffers;
    Buffer compositePosBuffer;
    Buffer compositeUvBuffer;
    Buffer quadDeformBuffer;
    GlobalsData globalsData;
    ParamsData paramsData;
    GpuImage mainAlbedo;
    GpuImage mainEmissive;
    GpuImage mainBump;
    GpuImage mainDepth;
    GpuImage dynamicDummyColor;
    GpuImage dynamicDummyDepth;
    VkCommandPool commandPool;
    VkCommandBuffer[] frameCommands;
    VkCommandBuffer commandBeforeDynamic;
    VkSemaphore imageAvailable;
    VkSemaphore renderFinished;
    VkFence[] inFlightFences;
    uint framebufferWidth;
    uint framebufferHeight;
    bool initialized;
    bool swapchainValid;
    bool maskContentActive;
    BlendMode currentBlendMode = BlendMode.Normal;
    bool useAdvancedBlend = false;
    bool advancedBlendCoherent = false;

    RenderResourceHandle nextHandle = 1;
    RenderResourceHandle framebufferId;
    RenderResourceHandle renderImageId;
    RenderResourceHandle mainAlbedoId;
    RenderResourceHandle mainEmissiveId;
    RenderResourceHandle mainBumpId;
    RenderResourceHandle blendFramebufferId;
    RenderResourceHandle blendAlbedoId;
    RenderResourceHandle blendEmissiveId;
    RenderResourceHandle blendBumpId;

    auto unsupported(T = void)(string func) {
        enforce(false, "Vulkan backend not implemented: "~func);
        static if (!is(T == void)) {
            return T.init;
        }
    }

public:
    this() {
        framebufferId = nextHandle++;
        renderImageId = nextHandle++;
        mainAlbedoId = nextHandle++;
        mainEmissiveId = nextHandle++;
        mainBumpId = nextHandle++;
        blendFramebufferId = nextHandle++;
        blendAlbedoId = nextHandle++;
        blendEmissiveId = nextHandle++;
        blendBumpId = nextHandle++;
    }
    ~this() {
        shutdown();
    }

    void initializeRenderer() {
        loadLibrary();
        createInstance();
        pickPhysicalDevice();
        createDeviceAndQueue();
        createCommandPool();
        createSyncObjects();
        detectGlslc();
        if (surface !is null) {
            recreateSwapchain();
        }
        if (descriptorSetLayout is null) {
            createDescriptorSetLayout();
        }
        if (pipelineLayout is null) {
            createPipelineLayout();
        }
        createDescriptorPoolAndSet();
        recreatePipelines();
        initialized = true;
        // TODO: create offscreen targets, pipelines, etc.
    }

    void resizeViewportTargets(int width, int height) {
        framebufferWidth = cast(uint)width;
        framebufferHeight = cast(uint)height;
        if (surface !is null && device !is null) {
            recreateSwapchain();
        }
    }

    void dumpViewport(ref ubyte[] data, int width, int height) {
        enforce(swapchain !is null && swapImages.length > 0, "Swapchain not initialized");
        if (currentImageIndex >= swapImages.length) {
            enforce(false, "Invalid swapchain image index");
        }
        size_t pixelSize = 4;
        size_t expected = cast(size_t)width * cast(size_t)height * pixelSize;
        if (data.length < expected) {
            data.length = expected;
        }

        Buffer staging = createBuffer(expected, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);

        transitionImageLayout(swapImages[currentImageIndex], swapFormat,
            VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);

        VkBufferImageCopy region = void;
        region.bufferOffset = 0;
        region.bufferRowLength = 0;
        region.bufferImageHeight = 0;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;
        region.imageOffset = VkOffset3D(0, 0, 0);
        region.imageExtent = VkExtent3D(cast(uint)width, cast(uint)height, 1);

        auto cmd = beginSingleTimeCommands();
        vkCmdCopyImageToBuffer(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            staging.buffer, 1, &region);
        endSingleTimeCommands(cmd);

        transitionImageLayout(swapImages[currentImageIndex], swapFormat,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_ASPECT_COLOR_BIT);

        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto src = cast(ubyte*)mapped;
        auto copyLen = expected < data.length ? expected : data.length;
        data[0 .. copyLen] = src[0 .. copyLen];
        vkUnmapMemory(device, staging.memory);
    }

    void beginScene() {
        enforce(initialized, "Vulkan backend not initialized");
        auto fence = inFlightFences[currentFrame];
        vkWaitForFences(device, 1, &fence, VK_TRUE, ulong.max);
        vkResetFences(device, 1, &fence);

        if (swapchain is null) {
            enforce(false, "Swapchain is not created. Call setSurface and resizeViewportTargets first.");
        }

        VkResult acquireRes = vkAcquireNextImageKHR(device, swapchain, ulong.max, imageAvailable, VK_NULL_HANDLE, &currentImageIndex);
        if (acquireRes == VK_ERROR_OUT_OF_DATE_KHR) {
            recreateSwapchain();
            swapchainValid = false;
            return;
        }
        enforce(acquireRes == VK_SUCCESS || acquireRes == VK_SUBOPTIMAL_KHR, "Failed to acquire swapchain image");
        swapchainValid = true;

        auto cmd = frameCommands[currentFrame];
        VkCommandBufferBeginInfo beginInfo = void;
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        enforce(vkBeginCommandBuffer(cmd, &beginInfo) == VK_SUCCESS,
            "Failed to begin command buffer");
        activeCommand = cmd;

        VkClearValue clearColor = void;
        clearColor.color.float32 = [0.0f, 0.0f, 0.0f, 1.0f];

        VkRenderPassBeginInfo rpBegin = void;
        rpBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass = offscreenRenderPass;
        rpBegin.framebuffer = offscreenFramebuffer;
        rpBegin.renderArea.offset = VkOffset2D(0, 0);
        rpBegin.renderArea.extent = swapExtent;
        VkClearValue[4] clears;
        clears[0] = clearColor;
        clears[1] = clearColor;
        clears[2] = clearColor;
        clears[3].depthStencil = VkClearDepthStencilValue(1.0f, 0);
        rpBegin.clearValueCount = 4;
        rpBegin.pClearValues = clears.ptr;

        vkCmdBeginRenderPass(cmd, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);
        VkViewport viewport = VkViewport(0, 0, cast(float)swapExtent.width, cast(float)swapExtent.height, 0.0f, 1.0f);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0), swapExtent);
        vkCmdSetViewport(cmd, 0, 1, &viewport);
        vkCmdSetScissor(cmd, 0, 1, &scissor);
        // Default UBO values (caller can override later)
        globalsData.mvp = mat4.identity;
        globalsData.offset = vec2(0, 0);
        updateGlobalsUBO(globalsData);
        paramsData.opacity = 1.0f;
        paramsData.multColor = vec3(1, 1, 1);
        paramsData.screenColor = vec3(0, 0, 0);
        paramsData.emissionStrength = 1.0f;
        updateParamsUBO(paramsData);
        maskContentActive = false;
    }

    void endScene() {
        enforce(initialized, "Vulkan backend not initialized");
        auto cmd = frameCommands[currentFrame];
        vkCmdEndRenderPass(cmd);
        if (swapchainValid) {
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);

            VkImageBlit blit = void;
            blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.srcSubresource.mipLevel = 0;
            blit.srcSubresource.baseArrayLayer = 0;
            blit.srcSubresource.layerCount = 1;
            blit.srcOffsets[0] = VkOffset3D(0, 0, 0);
            blit.srcOffsets[1] = VkOffset3D(cast(int)swapExtent.width, cast(int)swapExtent.height, 1);
            blit.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.dstSubresource.mipLevel = 0;
            blit.dstSubresource.baseArrayLayer = 0;
            blit.dstSubresource.layerCount = 1;
            blit.dstOffsets[0] = VkOffset3D(0, 0, 0);
            blit.dstOffsets[1] = VkOffset3D(cast(int)swapExtent.width, cast(int)swapExtent.height, 1);

            vkCmdBlitImage(cmd,
                mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1, &blit, VK_FILTER_LINEAR);

            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_ASPECT_COLOR_BIT);
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
        }
        enforce(vkEndCommandBuffer(cmd) == VK_SUCCESS,
            "Failed to end command buffer");

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submitInfo = void;
        submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.waitSemaphoreCount = 1;
        submitInfo.pWaitSemaphores = &imageAvailable;
        submitInfo.pWaitDstStageMask = &waitStage;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &cmd;
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &renderFinished;

        enforce(vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlightFences[currentFrame]) == VK_SUCCESS,
            "Failed to submit command buffer");

        VkPresentInfoKHR presentInfo = void;
        presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        presentInfo.waitSemaphoreCount = 1;
        presentInfo.pWaitSemaphores = &renderFinished;
        presentInfo.swapchainCount = 1;
        presentInfo.pSwapchains = &swapchain;
        presentInfo.pImageIndices = &currentImageIndex;

        VkResult presentRes = vkQueuePresentKHR(presentQueue, &presentInfo);
        if (presentRes == VK_ERROR_OUT_OF_DATE_KHR || presentRes == VK_SUBOPTIMAL_KHR) {
            recreateSwapchain();
            swapchainValid = false;
        } else {
            enforce(presentRes == VK_SUCCESS, "Failed to present swapchain image");
        }

        activeCommand = null;
        currentFrame = (currentFrame + 1) % maxFramesInFlight;
    }
    void postProcessScene() { /* TODO: implement post-processing path */ }

    void initializeDrawableResources() {
        destroyBuffer(globalsUbo);
        destroyBuffer(paramsUbo);
        destroyBuffer(sharedVertexBuffer);
        destroyBuffer(sharedUvBuffer);
        destroyBuffer(sharedDeformBuffer);
        destroyBuffer(compositePosBuffer);
        destroyBuffer(compositeUvBuffer);
        destroyBuffer(quadDeformBuffer);
        foreach (ref buf; indexBuffers) {
            destroyBuffer(buf);
        }
        indexBuffers.clear();
    }
    void bindDrawableVao() { /* NOP: Vulkan uses pipeline state */ }
    void createDrawableBuffers(out RenderResourceHandle ibo) { ibo = nextHandle++; indexBuffers[ibo] = Buffer.init; }
    void uploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
        auto entry = ibo in indexBuffers;
        if (entry is null || indices.length == 0) return;
        destroyBuffer(*entry);
        size_t sz = indices.length * ushort.sizeof;
        Buffer staging = createBuffer(sz, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);
        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto dst = cast(ubyte*)mapped;
        auto srcBytes = cast(const(ubyte)[])indices;
        dst[0 .. srcBytes.length] = srcBytes[];
        vkUnmapMemory(device, staging.memory);

        Buffer gpu = createBuffer(sz, VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        copyBuffer(staging, gpu, sz);
        indexBuffers[ibo] = gpu;
    }
    void uploadSharedVertexBuffer(Vec2Array vertices) {
        auto arr = vertices.toArray();
        if (arr.length == 0) return;
        float[] packed;
        packed.length = arr.length * 2;
        foreach (i, v; arr) {
            packed[i * 2 + 0] = v.x;
            packed[i * 2 + 1] = v.y;
        }
        uploadSharedBuffer(sharedVertexBuffer, packed);
    }
    void uploadSharedUvBuffer(Vec2Array uvs) {
        auto arr = uvs.toArray();
        if (arr.length == 0) return;
        float[] packed;
        packed.length = arr.length * 2;
        foreach (i, v; arr) {
            packed[i * 2 + 0] = v.x;
            packed[i * 2 + 1] = v.y;
        }
        uploadSharedBuffer(sharedUvBuffer, packed);
    }
    void uploadSharedDeformBuffer(Vec2Array deform) {
        auto arr = deform.toArray();
        if (arr.length == 0) return;
        float[] packed;
        packed.length = arr.length * 2;
        foreach (i, v; arr) {
            packed[i * 2 + 0] = v.x;
            packed[i * 2 + 1] = v.y;
        }
        uploadSharedBuffer(sharedDeformBuffer, packed);
    }
    void drawDrawableElements(RenderResourceHandle ibo, size_t indexCount) {
        if (activeCommand is null || indexCount == 0) return;
        auto entry = ibo in indexBuffers;
        if (entry is null || (*entry).buffer is null) return;
        VkBuffer[3] vertexBuffers;
        VkDeviceSize[3] offsets;
        size_t bindingCount = 0;
        if (sharedVertexBuffer.buffer !is null) {
            vertexBuffers[bindingCount] = sharedVertexBuffer.buffer;
            offsets[bindingCount] = 0;
            ++bindingCount;
        }
        if (sharedUvBuffer.buffer !is null) {
            vertexBuffers[bindingCount] = sharedUvBuffer.buffer;
            offsets[bindingCount] = 0;
            ++bindingCount;
        }
        if (sharedDeformBuffer.buffer !is null) {
            vertexBuffers[bindingCount] = sharedDeformBuffer.buffer;
            offsets[bindingCount] = 0;
            ++bindingCount;
        }
        if (bindingCount > 0) {
            vkCmdBindVertexBuffers(activeCommand, 0, cast(uint)bindingCount, vertexBuffers.ptr, offsets.ptr);
        }
        vkCmdBindIndexBuffer(activeCommand, (*entry).buffer, 0, VK_INDEX_TYPE_UINT16);
        vkCmdDrawIndexed(activeCommand, cast(uint)indexCount, 1, 0, 0, 0);
    }

    void uploadSharedBuffer(ref Buffer target, float[] data) {
        destroyBuffer(target);
        if (data.length == 0) return;
        size_t sz = data.length * float.sizeof;
        Buffer staging = createBuffer(sz, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);
        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto dst = cast(float*)mapped;
        dst[0 .. data.length] = data[];
        vkUnmapMemory(device, staging.memory);

        Buffer gpu = createBuffer(sz, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        copyBuffer(staging, gpu, sz);
        target = gpu;
    }

    DynamicCompositeState* decodeDynamicComposite(RenderResourceHandle handle) const {
        return handle == 0 ? null : cast(DynamicCompositeState*)cast(size_t)handle;
    }
    RenderResourceHandle encodeDynamicComposite(DynamicCompositeState* state) const {
        return cast(RenderResourceHandle)cast(size_t)state;
    }

    void ensureDynamicDummyImages(VkExtent2D extent) {
        if (dynamicDummyColor.image is null || dynamicDummyColor.extent != extent) {
            destroyImage(dynamicDummyColor);
            dynamicDummyColor = createImage(extent, VK_FORMAT_R8G8B8A8_UNORM,
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, VK_IMAGE_ASPECT_COLOR_BIT, 1);
        }
        if (dynamicDummyDepth.image is null || dynamicDummyDepth.extent != extent) {
            destroyImage(dynamicDummyDepth);
            dynamicDummyDepth = createImage(extent, VK_FORMAT_D24_UNORM_S8_UINT,
                VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT, 1);
        }
    }

    DynamicCompositeState* createDynamicCompositeFramebuffer(DynamicCompositeSurface surface) {
        if (surface is null || surface.textureCount == 0) return null;
        auto tex0 = surface.textures[0];
        if (tex0 is null) return null;
        auto vkTex0 = cast(VkTextureHandle)tex0.backendHandle();
        if (vkTex0 is null || vkTex0.image.view is null) return null;
        VkExtent2D extent = VkExtent2D(vkTex0.width, vkTex0.height);
        ensureDynamicDummyImages(extent);

        auto state = decodeDynamicComposite(surface.framebuffer);
        if (state is null) {
            state = new DynamicCompositeState();
            surface.framebuffer = encodeDynamicComposite(state);
        } else if (state.extent != extent && state.framebuffer !is null) {
            vkDestroyFramebuffer(device, state.framebuffer, null);
            state.framebuffer = null;
        }
        state.extent = extent;

        VkImageView[4] attachments;
        foreach (i; 0 .. 3) {
            attachments[i] = dynamicDummyColor.view;
        }
        foreach (i; 0 .. surface.textureCount) {
            auto t = surface.textures[i];
            auto vkTex = t is null ? null : cast(VkTextureHandle)t.backendHandle();
            if (vkTex !is null && vkTex.image.view !is null) {
                attachments[i] = vkTex.image.view;
            }
        }
        auto stencil = surface.stencil;
        if (stencil !is null) {
            auto vkStencil = cast(VkTextureHandle)stencil.backendHandle();
            if (vkStencil !is null && vkStencil.image.view !is null) {
                attachments[3] = vkStencil.image.view;
            } else {
                attachments[3] = dynamicDummyDepth.view;
            }
        } else {
            attachments[3] = dynamicDummyDepth.view;
        }

        if (state.framebuffer !is null) {
            vkDestroyFramebuffer(device, state.framebuffer, null);
            state.framebuffer = null;
        }

        VkFramebufferCreateInfo fb = void;
        fb.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb.renderPass = offscreenRenderPass;
        fb.attachmentCount = 4;
        fb.pAttachments = attachments.ptr;
        fb.width = extent.width;
        fb.height = extent.height;
        fb.layers = 1;
        enforce(vkCreateFramebuffer(device, &fb, null, &state.framebuffer) == VK_SUCCESS,
            "Failed to create dynamic composite framebuffer");
        return state;
    }

    bool supportsAdvancedBlend() { return false; }
    bool supportsAdvancedBlendCoherent() { return false; }
    void setAdvancedBlendCoherent(bool enabled) {
        advancedBlendCoherent = enabled;
    }
    void setLegacyBlendMode(BlendMode mode) {
        currentBlendMode = mode;
        useAdvancedBlend = false;
        recreatePipelines();
    }
    void setAdvancedBlendEquation(BlendMode mode) {
        currentBlendMode = mode;
        useAdvancedBlend = true;
        recreatePipelines();
    }
    void issueBlendBarrier() { /* Vulkan has implicit ordering for same-queue color; no-op */ }
    void initDebugRenderer() { /* TODO */ }
    void setDebugPointSize(float size) { /* TODO */ }
    void setDebugLineWidth(float size) { /* TODO */ }
    void uploadDebugBuffer(Vec3Array points, ushort[] indices) { /* TODO */ }
    void setDebugExternalBuffer(RenderResourceHandle vbo, RenderResourceHandle ibo, int count) { /* TODO */ }
    void drawDebugPoints(vec4 color, mat4 mvp) { /* TODO */ }
    void drawDebugLines(vec4 color, mat4 mvp) { /* TODO */ }

    void drawPartPacket(ref PartDrawPacket packet) {
        if (!packet.renderable || packet.textures.length == 0) return;
        if (activeCommand is null) return;
        auto cam = inGetCamera();
        globalsData.mvp = cam.matrix * packet.puppetMatrix * packet.modelMatrix;
        globalsData.offset = packet.origin;
        updateGlobalsUBO(globalsData);

        paramsData.opacity = packet.opacity;
        paramsData.multColor = packet.clampedTint;
        paramsData.screenColor = packet.clampedScreen;
        paramsData.emissionStrength = packet.emissionStrength;
        updateParamsUBO(paramsData);

        foreach (i, tex; packet.textures) {
            if (tex !is null) {
                bindTextureHandle(tex.backendHandle(), cast(uint)(i + 1));
            }
        }

        useShader(null);
        drawDrawableElements(packet.indexBuffer, packet.indexCount);
    }
    void beginDynamicComposite(DynamicCompositePass pass) {
        if (pass is null || pass.surface is null) return;
        auto state = createDynamicCompositeFramebuffer(pass.surface);
        if (state is null) return;
        // Allocate a transient command buffer for this composite pass.
        VkCommandBufferAllocateInfo alloc = void;
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.commandPool = commandPool;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = 1;
        VkCommandBuffer cmd;
        enforce(vkAllocateCommandBuffers(device, &alloc, &cmd) == VK_SUCCESS,
            "Failed to allocate dynamic composite command buffer");

        VkCommandBufferBeginInfo beginInfo = void;
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        enforce(vkBeginCommandBuffer(cmd, &beginInfo) == VK_SUCCESS,
            "Failed to begin dynamic composite command buffer");

        // Transition attachments to renderable.
        foreach (i; 0 .. pass.surface.textureCount) {
            auto tex = pass.surface.textures[i];
            auto vkTex = tex is null ? null : cast(VkTextureHandle)tex.backendHandle();
            if (vkTex !is null && vkTex.image.image !is null) {
                recordTransition(cmd, vkTex.image.image,
                    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    vkTex.image.aspect, vkTex.image.mipLevels);
            }
        }
        if (pass.surface.stencil !is null) {
            auto vkStencil = cast(VkTextureHandle)pass.surface.stencil.backendHandle();
            if (vkStencil !is null && vkStencil.image.image !is null) {
                recordTransition(cmd, vkStencil.image.image,
                    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    vkStencil.image.aspect, vkStencil.image.mipLevels);
            }
        }

        VkClearValue[4] clears;
        foreach (i; 0 .. 3) {
            clears[i].color.float32 = [0, 0, 0, 0];
        }
        clears[3].depthStencil = VkClearDepthStencilValue(1.0f, 0);

        VkRenderPassBeginInfo rpBegin = void;
        rpBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass = offscreenRenderPass;
        rpBegin.framebuffer = state.framebuffer;
        rpBegin.renderArea.offset = VkOffset2D(0, 0);
        rpBegin.renderArea.extent = state.extent;
        rpBegin.clearValueCount = 4;
        rpBegin.pClearValues = clears.ptr;

        vkCmdBeginRenderPass(cmd, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);
        VkViewport viewport = VkViewport(0, 0, cast(float)state.extent.width, cast(float)state.extent.height, 0.0f, 1.0f);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0), state.extent);
        vkCmdSetViewport(cmd, 0, 1, &viewport);
        vkCmdSetScissor(cmd, 0, 1, &scissor);

        commandBeforeDynamic = activeCommand;
        activeCommand = cmd;
        // Keep command buffer stored temporarily in pass.surface.framebuffer state for endDynamicComposite
        pass.surface.framebuffer = encodeDynamicComposite(state);
    }
    void endDynamicComposite(DynamicCompositePass pass) {
        if (pass is null || pass.surface is null) return;
        auto state = decodeDynamicComposite(pass.surface.framebuffer);
        if (state is null) return;
        auto cmd = activeCommand;
        if (cmd is null) return;
        vkCmdEndRenderPass(cmd);

        // Transition attachments back to shader-read.
        foreach (i; 0 .. pass.surface.textureCount) {
            auto tex = pass.surface.textures[i];
            auto vkTex = tex is null ? null : cast(VkTextureHandle)tex.backendHandle();
            if (vkTex !is null && vkTex.image.image !is null) {
                recordTransition(cmd, vkTex.image.image,
                    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    vkTex.image.aspect, vkTex.image.mipLevels);
            }
        }
        if (pass.surface.stencil !is null) {
            auto vkStencil = cast(VkTextureHandle)pass.surface.stencil.backendHandle();
            if (vkStencil !is null && vkStencil.image.image !is null) {
                recordTransition(cmd, vkStencil.image.image,
                    VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    vkStencil.image.aspect, vkStencil.image.mipLevels);
            }
        }

        enforce(vkEndCommandBuffer(cmd) == VK_SUCCESS, "Failed to end dynamic composite command buffer");

        VkSubmitInfo submit = void;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        enforce(vkQueueSubmit(graphicsQueue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS,
            "Failed to submit dynamic composite");
        vkQueueWaitIdle(graphicsQueue);

        vkFreeCommandBuffers(device, commandPool, 1, &cmd);
        activeCommand = commandBeforeDynamic;
        commandBeforeDynamic = null;

        // Regenerate mipmaps on first attachment for sampling quality.
        if (pass.surface.textureCount > 0 && pass.surface.textures[0] !is null) {
            pass.surface.textures[0].genMipmap();
        }
    }
    void destroyDynamicComposite(DynamicCompositeSurface surface) {
        if (surface is null) return;
        auto state = decodeDynamicComposite(surface.framebuffer);
        if (state !is null && state.framebuffer !is null) {
            vkDestroyFramebuffer(device, state.framebuffer, null);
            state.framebuffer = null;
        }
        surface.framebuffer = 0;
    }

    void beginMask(bool useStencil) {
        if (activeCommand is null || maskPipeline is null) return;
        maskContentActive = false;
        VkClearAttachment clear = void;
        clear.aspectMask = VK_IMAGE_ASPECT_STENCIL_BIT;
        clear.colorAttachment = 0;
        clear.clearValue.depthStencil = VkClearDepthStencilValue(1.0f, useStencil ? 0 : 1);
        VkClearRect clearRect = void;
        clearRect.rect = VkRect2D(VkOffset2D(0, 0), swapExtent);
        clearRect.baseArrayLayer = 0;
        clearRect.layerCount = 1;
        vkCmdClearAttachments(activeCommand, 1, &clear, 1, &clearRect);
        vkCmdBindPipeline(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, maskPipeline);
        if (descriptorSet !is null) {
            vkCmdBindDescriptorSets(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptorSet, 0, null);
        }
        vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilCompareMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilReference(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, useStencil ? 0 : 1);
    }

    void applyMask(ref MaskApplyPacket packet) {
        if (activeCommand is null || maskPipeline is null) return;
        vkCmdBindPipeline(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, maskPipeline);
        if (descriptorSet !is null) {
            vkCmdBindDescriptorSets(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptorSet, 0, null);
        }
        vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilCompareMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilReference(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, packet.isDodge ? 0 : 1);

        auto cam = inGetCamera();
        switch (packet.kind) {
            case MaskDrawableKind.Part:
                globalsData.mvp = cam.matrix * packet.partPacket.puppetMatrix * packet.partPacket.modelMatrix;
                globalsData.offset = packet.partPacket.origin;
                break;
            case MaskDrawableKind.Mask:
                globalsData.mvp = packet.maskPacket.mvp;
                globalsData.offset = packet.maskPacket.origin;
                break;
            default: break;
        }
        updateGlobalsUBO(globalsData);
        // Params not used here

        // Bind vertex/deform buffers (bindings 0 and 2)
        if (sharedVertexBuffer.buffer is null || sharedDeformBuffer.buffer is null) return;
        VkBuffer[3] vertexBuffers;
        VkDeviceSize[3] offsets;
        vertexBuffers[0] = sharedVertexBuffer.buffer;
        offsets[0] = 0;
        vertexBuffers[1] = VkBuffer.init; // unused binding 1
        offsets[1] = 0;
        vertexBuffers[2] = sharedDeformBuffer.buffer;
        offsets[2] = 0;
        vkCmdBindVertexBuffers(activeCommand, 0, 3, vertexBuffers.ptr, offsets.ptr);
        RenderResourceHandle ibo = packet.maskPacket.indexBuffer;
        uint idxCount = packet.maskPacket.indexCount;
        if (packet.kind == MaskDrawableKind.Part) {
            ibo = packet.partPacket.indexBuffer;
            idxCount = packet.partPacket.indexCount;
        }
        auto entry = ibo in indexBuffers;
        if (entry !is null && (*entry).buffer !is null) {
            vkCmdBindIndexBuffer(activeCommand, (*entry).buffer, 0, VK_INDEX_TYPE_UINT16);
            vkCmdDrawIndexed(activeCommand, idxCount, 1, 0, 0, 0);
        }
    }

    void beginMaskContent() {
        if (activeCommand is null) return;
        maskContentActive = true;
        vkCmdSetStencilCompareMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0x00);
        vkCmdSetStencilReference(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 1);
    }
    void endMask() {
        maskContentActive = false;
        if (activeCommand is null) return;
        vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilCompareMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        vkCmdSetStencilReference(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0);
    }

    void ensureQuadBuffers() {
        if (quadDeformBuffer.buffer is null) {
            float[12] zeroDeform = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
            uploadBufferData(quadDeformBuffer, zeroDeform[]);
        }
    }

    void drawQuadTexture(Texture texture, rect uvs,
                         mat4 transform, float opacity,
                         vec3 color, vec3 screenColor, Camera cam) {
        if (texture is null || activeCommand is null) return;
        ensureQuadBuffers();
        float[12] positions = [
            -0.5f, -0.5f,
            0.5f, -0.5f,
            -0.5f, 0.5f,
            0.5f, 0.5f,
            -0.5f, 0.5f,
            0.5f, -0.5f,
        ];
        float u0 = uvs.x;
        float u1 = uvs.width;
        float v0 = uvs.y;
        float v1 = uvs.height;
        float[12] uvData = [
            u0, v0,
            u1, v0,
            u0, v1,
            u1, v1,
            u0, v1,
            u1, v0,
        ];
        uploadBufferData(compositePosBuffer, positions[]);
        uploadBufferData(compositeUvBuffer, uvData[]);

        auto cameraMatrix = cam is null ? inGetCamera().matrix : cam.matrix;
        globalsData.mvp = cameraMatrix * transform;
        globalsData.offset = vec2(0, 0);
        updateGlobalsUBO(globalsData);

        paramsData.opacity = opacity;
        paramsData.multColor = color;
        paramsData.screenColor = screenColor;
        paramsData.emissionStrength = 1.0f;
        updateParamsUBO(paramsData);

        bindTextureHandle(texture.backendHandle(), 1);
        bindTextureHandle(texture.backendHandle(), 2);
        bindTextureHandle(texture.backendHandle(), 3);

        auto pipeline = maskContentActive && basicMaskedPipeline !is null ? basicMaskedPipeline : basicPipeline;
        if (pipeline is null) return;
        vkCmdBindPipeline(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (descriptorSet !is null) {
            vkCmdBindDescriptorSets(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptorSet, 0, null);
        }
        if (maskContentActive) {
            vkCmdSetStencilCompareMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
            vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0x00);
            vkCmdSetStencilReference(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 1);
        }
        VkBuffer[3] vertexBuffers = [compositePosBuffer.buffer, compositeUvBuffer.buffer, quadDeformBuffer.buffer];
        VkDeviceSize[3] offsets = [0, 0, 0];
        vkCmdBindVertexBuffers(activeCommand, 0, 3, vertexBuffers.ptr, offsets.ptr);
        vkCmdDraw(activeCommand, 6, 1, 0, 0);
    }

    void drawTextureAtPart(Texture texture, Part part) {
        if (texture is null || part is null) return;
        auto modelMatrix = part.immediateModelMatrix();
        mat4 puppetMatrix = mat4.identity;
        if (!part.ignorePuppet && part.puppet !is null) {
            puppetMatrix = part.puppet.transform.matrix;
        }
        auto transform = puppetMatrix * modelMatrix * mat4.scaling(cast(float)texture.width(), cast(float)texture.height(), 1);
        rect uvRect = rect(0, 0, 1, 1);
        drawQuadTexture(texture, uvRect, transform, part.opacity, part.tint, part.screenTint, null);
    }

    void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                                        vec3 color, vec3 screenColor) {
        if (texture is null) return;
        auto translate = mat4.translation(position.x, position.y, 0);
        auto scale = mat4.scaling(cast(float)texture.width(), cast(float)texture.height(), 1);
        rect uvRect = rect(0, 0, 1, 1);
        drawQuadTexture(texture, uvRect, translate * scale, opacity, color, screenColor, null);
    }
    void drawTextureAtRect(Texture texture, rect area, rect uvs,
                                    float opacity, vec3 color, vec3 screenColor,
                                    Shader shader = null, Camera cam = null) {
        if (texture is null) return;
        float left = area.left;
        float right = area.right;
        float top = area.top;
        float bottom = area.bottom;
        float width = right - left;
        float height = bottom - top;
        auto translate = mat4.translation((left + right) * 0.5f, (top + bottom) * 0.5f, 0);
        auto scale = mat4.scaling(width, height, 1);
        drawQuadTexture(texture, uvs, translate * scale, opacity, color, screenColor, cam);
    }

    RenderResourceHandle framebufferHandle() { return framebufferId; }
    RenderResourceHandle renderImageHandle() { return renderImageId; }
    RenderResourceHandle mainAlbedoHandle() { return mainAlbedoId; }
    RenderResourceHandle mainEmissiveHandle() { return mainEmissiveId; }
    RenderResourceHandle mainBumpHandle() { return mainBumpId; }
    RenderResourceHandle blendFramebufferHandle() { return blendFramebufferId; }
    RenderResourceHandle blendAlbedoHandle() { return blendAlbedoId; }
    RenderResourceHandle blendEmissiveHandle() { return blendEmissiveId; }
    RenderResourceHandle blendBumpHandle() { return blendBumpId; }

    void addBasicLightingPostProcess() { /* TODO */ }

    void setDifferenceAggregationEnabled(bool enabled) { /* TODO */ }
    bool isDifferenceAggregationEnabled() { return false; }
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) { /* TODO */ }
    DifferenceEvaluationRegion getDifferenceAggregationRegion() { return DifferenceEvaluationRegion.init; }
    bool evaluateDifferenceAggregation(RenderResourceHandle texture, int width, int height) { return false; }
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        result = DifferenceEvaluationResult.init;
        return false;
    }

    RenderShaderHandle createShader(string vertexSource, string fragmentSource) {
        auto handle = new VkShaderHandle();
        handle.id = nextHandle++;
        auto vertSpv = compileGlslToSpirv("dynamic.vert", vertexSource, ".vert");
        auto fragSpv = compileGlslToSpirv("dynamic.frag", fragmentSource, ".frag");
        handle.vert = createShaderModule(vertSpv);
        handle.frag = createShaderModule(fragSpv);
        return handle;
    }

    void destroyShader(RenderShaderHandle shader) {
        auto sh = cast(VkShaderHandle)shader;
        if (sh is null) return;
        if (sh.vert !is null) {
            vkDestroyShaderModule(device, sh.vert, null);
            sh.vert = null;
        }
        if (sh.frag !is null) {
            vkDestroyShaderModule(device, sh.frag, null);
            sh.frag = null;
        }
    }

    void useShader(RenderShaderHandle shader) {
        if (activeCommand is null) return;
        auto pipeline = maskContentActive && basicMaskedPipeline !is null ? basicMaskedPipeline : basicPipeline;
        if (pipeline is null) return;
        vkCmdBindPipeline(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (maskContentActive) {
            vkCmdSetStencilCompareMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
            vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0x00);
            vkCmdSetStencilReference(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 1);
        } else {
            vkCmdSetStencilWriteMask(activeCommand, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
        }
        if (descriptorSet !is null) {
            vkCmdBindDescriptorSets(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptorSet, 0, null);
        }
    }

    enum UniformSlot {
        MVP = 0,
        Offset = 1,
        Opacity = 2,
        MultColor = 3,
        ScreenColor = 4,
        EmissionStrength = 5,
    }

    int getShaderUniformLocation(RenderShaderHandle shader, string name) {
        switch (name) {
            case "mvp": return UniformSlot.MVP;
            case "offset": return UniformSlot.Offset;
            case "opacity": return UniformSlot.Opacity;
            case "multColor": return UniformSlot.MultColor;
            case "screenColor": return UniformSlot.ScreenColor;
            case "emissionStrength": return UniformSlot.EmissionStrength;
            default: return -1;
        }
    }

    void setShaderUniform(RenderShaderHandle shader, int location, bool value) { /* not used */ }
    void setShaderUniform(RenderShaderHandle shader, int location, int value) {
        if (location == UniformSlot.Opacity) {
            paramsData.opacity = cast(float)value;
            updateParamsUBO(paramsData);
        }
    }
    void setShaderUniform(RenderShaderHandle shader, int location, float value) {
        if (location == UniformSlot.Opacity) {
            paramsData.opacity = value;
            updateParamsUBO(paramsData);
        } else if (location == UniformSlot.EmissionStrength) {
            paramsData.emissionStrength = value;
            updateParamsUBO(paramsData);
        }
    }
    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value) {
        if (location == UniformSlot.Offset) {
            globalsData.offset = value;
            updateGlobalsUBO(globalsData);
        }
    }
    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value) {
        if (location == UniformSlot.MultColor) {
            paramsData.multColor = value;
            updateParamsUBO(paramsData);
        } else if (location == UniformSlot.ScreenColor) {
            paramsData.screenColor = value;
            updateParamsUBO(paramsData);
        }
    }
    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value) {
        // No vec4 uniforms in basic shader; ignore
    }
    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value) {
        if (location == UniformSlot.MVP) {
            globalsData.mvp = value;
            updateGlobalsUBO(globalsData);
        }
    }

    RenderTextureHandle createTextureHandle() {
        auto handle = new VkTextureHandle();
        handle.id = nextHandle++;
        return handle;
    }

    void destroyTextureHandle(RenderTextureHandle texture) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null) return;
        if (handle.sampler !is null) {
            vkDestroySampler(device, handle.sampler, null);
            handle.sampler = null;
        }
        destroyImage(handle.image);
        handle.id = 0;
        handle.width = 0;
        handle.height = 0;
        handle.mipLevels = 1;
    }

    void bindTextureHandle(RenderTextureHandle texture, uint unit) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null || descriptorSet is null) return;
        enforce(unit >= 1 && unit <= 3, "Texture unit out of range for basic shader");
        VkDescriptorImageInfo imageInfo = void;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        imageInfo.imageView = handle.image.view;
        imageInfo.sampler = handle.sampler;

        VkWriteDescriptorSet write = void;
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = descriptorSet;
        write.dstBinding = unit;
        write.dstArrayElement = 0;
        write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &imageInfo;
        vkUpdateDescriptorSets(device, 1, &write, 0, null);
    }

    void uploadTextureData(RenderTextureHandle texture, int width, int height,
                                    int inChannels, int outChannels, bool stencil,
                                    ubyte[] data) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null) return;
        destroyImage(handle.image);
        if (handle.sampler !is null) {
            vkDestroySampler(device, handle.sampler, null);
            handle.sampler = null;
        }

        VkFormat format = VK_FORMAT_R8G8B8A8_UNORM;
        VkImageAspectFlags aspect = VK_IMAGE_ASPECT_COLOR_BIT;
        size_t pixelSize = 4;
        if (stencil) {
            format = VK_FORMAT_D24_UNORM_S8_UINT;
            aspect = VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT;
            pixelSize = 4; // data expected packed
        } else if (inChannels == 1 && outChannels == 1) {
            format = VK_FORMAT_R8_UNORM;
            pixelSize = 1;
        }

        size_t expected = cast(size_t)width * cast(size_t)height * pixelSize;
        Buffer staging = createBuffer(expected, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);
        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto dst = cast(ubyte*)mapped;
        if (stencil || pixelSize == inChannels) {
            auto copyLen = data.length < expected ? data.length : expected;
            dst[0 .. copyLen] = data[0 .. copyLen];
            if (copyLen < expected) dst[copyLen .. expected] = 0;
        } else if (inChannels == 3 && pixelSize == 4) {
            size_t srcIdx = 0;
            size_t dstIdx = 0;
            while (dstIdx < expected && srcIdx + 2 < data.length) {
                dst[dstIdx + 0] = data[srcIdx + 0];
                dst[dstIdx + 1] = data[srcIdx + 1];
                dst[dstIdx + 2] = data[srcIdx + 2];
                dst[dstIdx + 3] = 255;
                srcIdx += 3;
                dstIdx += 4;
            }
            if (dstIdx < expected) dst[dstIdx .. expected] = 0;
        } else {
            auto copyLen = data.length < expected ? data.length : expected;
            dst[0 .. copyLen] = data[0 .. copyLen];
            if (copyLen < expected) dst[copyLen .. expected] = 0;
        }
        vkUnmapMemory(device, staging.memory);

        import std.math : log2, floor;
        uint mipLevels = stencil ? 1 : (cast(uint)floor(log2(cast(float)(width > height ? width : height))) + 1);
        if (mipLevels == 0) mipLevels = 1;
        handle.image = createImage(VkExtent2D(cast(uint)width, cast(uint)height), format,
            VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, aspect, mipLevels);
        handle.mipLevels = mipLevels;
        transitionImageLayout(handle.image.image, format, VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, aspect, mipLevels);
        copyBufferToImage(staging, handle.image.image, cast(uint)width, cast(uint)height);
        transitionImageLayout(handle.image.image, format, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, aspect, mipLevels);

        recreateSampler(handle);
        if (!stencil && mipLevels > 1) {
            generateTextureMipmap(texture);
        }

        handle.width = cast(uint)width;
        handle.height = cast(uint)height;
        handle.id = handle.id == 0 ? nextHandle++ : handle.id;
    }

    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width,
                                      int height, int channels, ubyte[] data) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null || handle.image.image is null) {
            unsupported(__FUNCTION__);
            return;
        }
        if ((handle.image.aspect & VK_IMAGE_ASPECT_COLOR_BIT) == 0) {
            unsupported(__FUNCTION__);
            return;
        }
        size_t pixelSize = pixelSizeForFormat(handle.image.format);
        size_t expected = cast(size_t)width * cast(size_t)height * pixelSize;
        Buffer staging = createBuffer(expected, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);
        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto dst = cast(ubyte*)mapped;
        if (channels == pixelSize) {
            auto copyLen = data.length < expected ? data.length : expected;
            dst[0 .. copyLen] = data[0 .. copyLen];
            if (copyLen < expected) dst[copyLen .. expected] = 0;
        } else if (channels == 3 && pixelSize == 4) {
            size_t srcIdx = 0;
            size_t dstIdx = 0;
            while (dstIdx < expected && srcIdx + 2 < data.length) {
                dst[dstIdx + 0] = data[srcIdx + 0];
                dst[dstIdx + 1] = data[srcIdx + 1];
                dst[dstIdx + 2] = data[srcIdx + 2];
                dst[dstIdx + 3] = 255;
                srcIdx += 3;
                dstIdx += 4;
            }
            if (dstIdx < expected) dst[dstIdx .. expected] = 0;
        } else {
            auto copyLen = data.length < expected ? data.length : expected;
            dst[0 .. copyLen] = data[0 .. copyLen];
            if (copyLen < expected) dst[copyLen .. expected] = 0;
        }
        vkUnmapMemory(device, staging.memory);

        transitionImageLayout(handle.image.image, handle.image.format,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, handle.image.aspect);

        VkBufferImageCopy region = void;
        region.bufferOffset = 0;
        region.bufferRowLength = 0;
        region.bufferImageHeight = 0;
        region.imageSubresource.aspectMask = handle.image.aspect;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;
        region.imageOffset = VkOffset3D(cast(int)x, cast(int)y, 0);
        region.imageExtent = VkExtent3D(cast(uint)width, cast(uint)height, 1);

        auto cmd = beginSingleTimeCommands();
        vkCmdCopyBufferToImage(cmd, staging.buffer, handle.image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        endSingleTimeCommands(cmd);

        transitionImageLayout(handle.image.image, handle.image.format,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, handle.image.aspect, handle.mipLevels);
    }

    void generateTextureMipmap(RenderTextureHandle texture) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null || handle.image.image is null) return;
        if (handle.mipLevels <= 1) return;
        auto format = handle.image.format;
        auto aspect = handle.image.aspect;

        auto cmd = beginSingleTimeCommands();

        uint mipWidth = handle.width;
        uint mipHeight = handle.height;
        for (uint i = 1; i < handle.mipLevels; ++i) {
            VkImageMemoryBarrier[2] barriers;
            // Transition level i-1 to SRC
            barriers[0] = VkImageMemoryBarrier.init;
            barriers[0].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barriers[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barriers[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            barriers[0].image = handle.image.image;
            barriers[0].subresourceRange.aspectMask = aspect;
            barriers[0].subresourceRange.baseMipLevel = i - 1;
            barriers[0].subresourceRange.levelCount = 1;
            barriers[0].subresourceRange.baseArrayLayer = 0;
            barriers[0].subresourceRange.layerCount = 1;
            barriers[0].oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barriers[0].newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            barriers[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
            barriers[0].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

            // Transition level i to DST
            barriers[1] = barriers[0];
            barriers[1].subresourceRange.baseMipLevel = i;
            barriers[1].oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            barriers[1].newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barriers[1].srcAccessMask = 0;
            barriers[1].dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

            vkCmdPipelineBarrier(cmd,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                0, 0, null, 0, null, 2, barriers.ptr);

            VkImageBlit blit = void;
            blit.srcSubresource.aspectMask = aspect;
            blit.srcSubresource.mipLevel = i - 1;
            blit.srcSubresource.baseArrayLayer = 0;
            blit.srcSubresource.layerCount = 1;
            blit.srcOffsets[0] = VkOffset3D(0, 0, 0);
            blit.srcOffsets[1] = VkOffset3D(cast(int)mipWidth, cast(int)mipHeight, 1);

            mipWidth = mipWidth > 1 ? mipWidth / 2 : 1;
            mipHeight = mipHeight > 1 ? mipHeight / 2 : 1;

            blit.dstSubresource.aspectMask = aspect;
            blit.dstSubresource.mipLevel = i;
            blit.dstSubresource.baseArrayLayer = 0;
            blit.dstSubresource.layerCount = 1;
            blit.dstOffsets[0] = VkOffset3D(0, 0, 0);
            blit.dstOffsets[1] = VkOffset3D(cast(int)mipWidth, cast(int)mipHeight, 1);

            vkCmdBlitImage(cmd,
                handle.image.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                handle.image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1, &blit, VK_FILTER_LINEAR);

            // Transition level i-1 to shader read
            VkImageMemoryBarrier post = barriers[0];
            post.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            post.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            post.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            post.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
            vkCmdPipelineBarrier(cmd,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                0, 0, null, 0, null, 1, &post);
        }

        // Transition last level to shader read
        VkImageMemoryBarrier last = VkImageMemoryBarrier.init;
        last.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        last.image = handle.image.image;
        last.subresourceRange.aspectMask = aspect;
        last.subresourceRange.baseMipLevel = handle.mipLevels - 1;
        last.subresourceRange.levelCount = 1;
        last.subresourceRange.baseArrayLayer = 0;
        last.subresourceRange.layerCount = 1;
        last.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        last.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        last.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        last.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        last.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        last.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        vkCmdPipelineBarrier(cmd,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, null, 0, null, 1, &last);

        endSingleTimeCommands(cmd);
    }

    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering, bool useMipmaps = true) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null) return;
        handle.filtering = filtering;
        recreateSampler(handle);
    }

    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null) return;
        handle.wrapping = wrapping;
        recreateSampler(handle);
    }

    void applyTextureAnisotropy(RenderTextureHandle texture, float value) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null) return;
        handle.anisotropy = value;
        recreateSampler(handle);
    }

    float maxTextureAnisotropy() {
        return supportsAnisotropy ? maxSupportedAnisotropy : 1.0f;
    }

    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                                  ubyte[] buffer) {
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null || handle.image.image is null) {
            unsupported(__FUNCTION__);
            return;
        }
        if ((handle.image.aspect & VK_IMAGE_ASPECT_COLOR_BIT) == 0) {
            unsupported(__FUNCTION__);
            return;
        }
        size_t pixelSize = pixelSizeForFormat(handle.image.format);
        size_t expected = cast(size_t)handle.width * cast(size_t)handle.height * pixelSize;
        if (buffer.length < expected) {
            buffer.length = expected;
        }

        Buffer staging = createBuffer(expected, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);

        transitionImageLayout(handle.image.image, handle.image.format,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, handle.image.aspect, handle.mipLevels);

        VkBufferImageCopy region = void;
        region.bufferOffset = 0;
        region.bufferRowLength = 0;
        region.bufferImageHeight = 0;
        region.imageSubresource.aspectMask = handle.image.aspect;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;
        region.imageOffset = VkOffset3D(0, 0, 0);
        region.imageExtent = VkExtent3D(handle.width, handle.height, 1);

        auto cmd = beginSingleTimeCommands();
        vkCmdCopyImageToBuffer(cmd, handle.image.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.buffer, 1, &region);
        endSingleTimeCommands(cmd);

        transitionImageLayout(handle.image.image, handle.image.format,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, handle.image.aspect, handle.mipLevels);

        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto src = cast(ubyte*)mapped;
        auto copyLen = expected < buffer.length ? expected : buffer.length;
        buffer[0 .. copyLen] = src[0 .. copyLen];
        vkUnmapMemory(device, staging.memory);
    }

    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto handle = cast(VkTextureHandle)texture;
        return handle is null ? 0 : handle.id;
    }
    
    /// Platform integration should set the surface before initializeRenderer.
    void setSurface(VkSurfaceKHR surf) {
        surface = surf;
        if (initialized) {
            recreateSwapchain();
        }
    }

private:
    void loadLibrary() {
        enforce(loadGlobalLevelFunctions(), "Failed to load Vulkan loader");
    }

    void createInstance() {
        VkApplicationInfo appInfo = void;
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName = "nijilive".toStringz();
        appInfo.pEngineName = "nijilive".toStringz();
        appInfo.apiVersion = VK_API_VERSION_1_0;

        VkInstanceCreateInfo createInfo = void;
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.pApplicationInfo = &appInfo;

        enforce(vkCreateInstance(&createInfo, null, &instance) == VK_SUCCESS,
            "Failed to create Vulkan instance");

        loadInstanceLevelFunctions(instance);
    }

    void pickPhysicalDevice() {
        uint count = 0;
        enforce(vkEnumeratePhysicalDevices(instance, &count, null) == VK_SUCCESS && count > 0,
            "No Vulkan physical devices available");
        VkPhysicalDevice[] devices;
        devices.length = count;
        enforce(vkEnumeratePhysicalDevices(instance, &count, devices.ptr) == VK_SUCCESS,
            "Failed to enumerate Vulkan devices");
        // Simple selection: first device with graphics + present queue.
        foreach (dev; devices) {
            if (findQueueFamilies(dev)) {
                physicalDevice = dev;
                vkGetPhysicalDeviceFeatures(dev, &deviceFeatures);
                vkGetPhysicalDeviceProperties(dev, &deviceProperties);
                supportsAnisotropy = deviceFeatures.samplerAnisotropy == VK_TRUE;
                maxSupportedAnisotropy = deviceProperties.limits.maxSamplerAnisotropy;
                break;
            }
        }
        enforce(physicalDevice !is null, "No suitable Vulkan device with graphics queue found");
    }

    bool findQueueFamilies(VkPhysicalDevice dev) {
        uint count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &count, null);
        if (count == 0) return false;
        VkQueueFamilyProperties[] props;
        props.length = count;
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &count, props.ptr);
        uint graphicsIdx = uint.max;
        uint presentIdx = uint.max;
        foreach (i, p; props) {
            if ((p.queueFlags & VK_QUEUE_GRAPHICS_BIT) && graphicsIdx == uint.max) {
                graphicsIdx = cast(uint)i;
            }
            if (surface !is null && presentIdx == uint.max) {
                VkBool32 supports = VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(dev, cast(uint)i, surface, &supports);
                if (supports) {
                    presentIdx = cast(uint)i;
                }
            }
        }
        if (graphicsIdx == uint.max) return false;
        graphicsQueueFamily = graphicsIdx;
        presentQueueFamily = (presentIdx == uint.max) ? graphicsIdx : presentIdx;
        return true;
    }

    void createDeviceAndQueue() {
        float priority = 1.0f;
        VkDeviceQueueCreateInfo[2] queueInfos;
        uint queueInfoCount = 0;

        queueInfos[queueInfoCount].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queueInfos[queueInfoCount].queueFamilyIndex = graphicsQueueFamily;
        queueInfos[queueInfoCount].queueCount = 1;
        queueInfos[queueInfoCount].pQueuePriorities = &priority;
        queueInfoCount++;

        if (presentQueueFamily != graphicsQueueFamily) {
            queueInfos[queueInfoCount].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueInfos[queueInfoCount].queueFamilyIndex = presentQueueFamily;
            queueInfos[queueInfoCount].queueCount = 1;
            queueInfos[queueInfoCount].pQueuePriorities = &priority;
            queueInfoCount++;
        }

        VkDeviceCreateInfo createInfo = void;
        createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        createInfo.queueCreateInfoCount = queueInfoCount;
        createInfo.pQueueCreateInfos = queueInfos.ptr;
        VkPhysicalDeviceFeatures enabledFeatures = void;
        if (supportsAnisotropy) {
            enabledFeatures.samplerAnisotropy = VK_TRUE;
        }
        createInfo.pEnabledFeatures = &enabledFeatures;

        enforce(vkCreateDevice(physicalDevice, &createInfo, null, &device) == VK_SUCCESS,
            "Failed to create Vulkan device");

        loadDeviceLevelFunctions(device);
        vkGetDeviceQueue(device, graphicsQueueFamily, 0, &graphicsQueue);
        vkGetDeviceQueue(device, presentQueueFamily, 0, &presentQueue);
    }

    void createCommandPool() {
        VkCommandPoolCreateInfo info = void;
        info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        info.queueFamilyIndex = graphicsQueueFamily;
        info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        enforce(vkCreateCommandPool(device, &info, null, &commandPool) == VK_SUCCESS,
            "Failed to create command pool");

        frameCommands.length = maxFramesInFlight;
        VkCommandBufferAllocateInfo allocInfo = void;
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocInfo.commandPool = commandPool;
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocInfo.commandBufferCount = cast(uint)frameCommands.length;
        enforce(vkAllocateCommandBuffers(device, &allocInfo, frameCommands.ptr) == VK_SUCCESS,
            "Failed to allocate command buffers");
    }

    void createSyncObjects() {
        VkSemaphoreCreateInfo semInfo = void;
        semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        enforce(vkCreateSemaphore(device, &semInfo, null, &imageAvailable) == VK_SUCCESS,
            "Failed to create imageAvailable semaphore");
        enforce(vkCreateSemaphore(device, &semInfo, null, &renderFinished) == VK_SUCCESS,
            "Failed to create renderFinished semaphore");

        inFlightFences.length = maxFramesInFlight;
        VkFenceCreateInfo fenceInfo = void;
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        enforce(vkCreateFence(device, &fenceInfo, null, &inFlightFences[0]) == VK_SUCCESS,
            "Failed to create fence 0");
        enforce(vkCreateFence(device, &fenceInfo, null, &inFlightFences[1]) == VK_SUCCESS,
            "Failed to create fence 1");
        currentFrame = 0;
    }

    void recreateSwapchain() {
        if (surface is null || device is null) return;
        vkDeviceWaitIdle(device);
        destroySwapchainResources();

        VkSurfaceCapabilitiesKHR caps = void;
        enforce(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &caps) == VK_SUCCESS,
            "Failed to get surface capabilities");

        VkSurfaceFormatKHR format = chooseSurfaceFormat();
        VkPresentModeKHR presentMode = choosePresentMode();
        swapExtent = chooseSwapExtent(caps);
        swapFormat = format.format;

        uint imageCount = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
            imageCount = caps.maxImageCount;
        }

        VkSwapchainCreateInfoKHR ci = void;
        ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        ci.surface = surface;
        ci.minImageCount = imageCount;
        ci.imageFormat = format.format;
        ci.imageColorSpace = format.colorSpace;
        ci.imageExtent = swapExtent;
        ci.imageArrayLayers = 1;
        ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

        uint[2] queueFamilyIndices = [graphicsQueueFamily, presentQueueFamily];
        if (graphicsQueueFamily != presentQueueFamily) {
            ci.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
            ci.queueFamilyIndexCount = 2;
            ci.pQueueFamilyIndices = queueFamilyIndices.ptr;
        } else {
            ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        }
        ci.preTransform = caps.currentTransform;
        ci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        ci.presentMode = presentMode;
        ci.clipped = VK_TRUE;
        ci.oldSwapchain = VK_NULL_HANDLE;

        enforce(vkCreateSwapchainKHR(device, &ci, null, &swapchain) == VK_SUCCESS,
            "Failed to create swapchain");

        uint actualCount = 0;
        vkGetSwapchainImagesKHR(device, swapchain, &actualCount, null);
        swapImages.length = actualCount;
        enforce(vkGetSwapchainImagesKHR(device, swapchain, &actualCount, swapImages.ptr) == VK_SUCCESS,
            "Failed to get swapchain images");

        createImageViews();
        createRenderPass();
        createFramebuffers();
        createOffscreenTargets();
        if (descriptorSetLayout is null) {
            createDescriptorSetLayout();
        }
        if (pipelineLayout is null) {
            createPipelineLayout();
        }
        createDescriptorPoolAndSet();
        recreatePipelines();
        swapchainValid = true;
    }

    void destroySwapchainResources() {
        foreach (fb; swapFramebuffers) {
            if (fb !is null) vkDestroyFramebuffer(device, fb, null);
        }
        swapFramebuffers.length = 0;
        if (basicPipeline !is null) {
            vkDestroyPipeline(device, basicPipeline, null);
            basicPipeline = null;
        }
        if (basicMaskedPipeline !is null) {
            vkDestroyPipeline(device, basicMaskedPipeline, null);
            basicMaskedPipeline = null;
        }
        if (maskPipeline !is null) {
            vkDestroyPipeline(device, maskPipeline, null);
            maskPipeline = null;
        }
        if (compositePipeline !is null) {
            vkDestroyPipeline(device, compositePipeline, null);
            compositePipeline = null;
        }
        if (compositeMaskedPipeline !is null) {
            vkDestroyPipeline(device, compositeMaskedPipeline, null);
            compositeMaskedPipeline = null;
        }
        if (descriptorPool !is null) {
            vkDestroyDescriptorPool(device, descriptorPool, null);
            descriptorPool = null;
        }
        if (pipelineLayout !is null) {
            vkDestroyPipelineLayout(device, pipelineLayout, null);
            pipelineLayout = null;
        }
        if (descriptorSetLayout !is null) {
            vkDestroyDescriptorSetLayout(device, descriptorSetLayout, null);
            descriptorSetLayout = null;
        }
        if (descriptorPool !is null) {
            vkDestroyDescriptorPool(device, descriptorPool, null);
            descriptorPool = null;
        }
        if (offscreenFramebuffer !is null) {
            vkDestroyFramebuffer(device, offscreenFramebuffer, null);
            offscreenFramebuffer = null;
        }
        if (offscreenRenderPass !is null) {
            vkDestroyRenderPass(device, offscreenRenderPass, null);
            offscreenRenderPass = null;
        }
        if (offscreenRenderPassLoad !is null) {
            vkDestroyRenderPass(device, offscreenRenderPassLoad, null);
            offscreenRenderPassLoad = null;
        }
        if (renderPass !is null) {
            vkDestroyRenderPass(device, renderPass, null);
            renderPass = null;
        }
        if (swapchain !is null) {
            vkDestroySwapchainKHR(device, swapchain, null);
            swapchain = null;
        }
        foreach (view; swapImageViews) {
            if (view !is null) vkDestroyImageView(device, view, null);
        }
        swapImageViews.length = 0;
        destroyImage(mainAlbedo);
        destroyImage(mainEmissive);
        destroyImage(mainBump);
        destroyImage(mainDepth);
        destroyImage(dynamicDummyColor);
        destroyImage(dynamicDummyDepth);
        mainAlbedo = GpuImage.init;
        mainEmissive = GpuImage.init;
        mainBump = GpuImage.init;
        mainDepth = GpuImage.init;
        if (offscreenFramebuffer !is null) {
            vkDestroyFramebuffer(device, offscreenFramebuffer, null);
            offscreenFramebuffer = null;
        }
        if (offscreenRenderPass !is null) {
            vkDestroyRenderPass(device, offscreenRenderPass, null);
            offscreenRenderPass = null;
        }
    }

    VkSurfaceFormatKHR chooseSurfaceFormat() {
        uint count = 0;
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &count, null);
        enforce(count > 0, "No surface formats available");
        VkSurfaceFormatKHR[] formats;
        formats.length = count;
        vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &count, formats.ptr);
        foreach (f; formats) {
            if (f.format == VK_FORMAT_B8G8R8A8_UNORM && f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return f;
            }
        }
        return formats[0];
    }

    VkPresentModeKHR choosePresentMode() {
        uint count = 0;
        vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface, &count, null);
        VkPresentModeKHR[] modes;
        modes.length = count;
        vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice, surface, &count, modes.ptr);
        foreach (m; modes) {
            if (m == VK_PRESENT_MODE_MAILBOX_KHR) return m;
        }
        return VK_PRESENT_MODE_FIFO_KHR;
    }

    VkExtent2D chooseSwapExtent(VkSurfaceCapabilitiesKHR caps) {
        if (caps.currentExtent.width != uint.max) {
            return caps.currentExtent;
        }
        VkExtent2D extent;
        extent.width = framebufferWidth > 0 ? framebufferWidth : caps.minImageExtent.width;
        extent.height = framebufferHeight > 0 ? framebufferHeight : caps.minImageExtent.height;
        if (extent.width < caps.minImageExtent.width) extent.width = caps.minImageExtent.width;
        if (extent.height < caps.minImageExtent.height) extent.height = caps.minImageExtent.height;
        if (extent.width > caps.maxImageExtent.width) extent.width = caps.maxImageExtent.width;
        if (extent.height > caps.maxImageExtent.height) extent.height = caps.maxImageExtent.height;
        return extent;
    }

    void createImageViews() {
        swapImageViews.length = swapImages.length;
        for (size_t i = 0; i < swapImages.length; ++i) {
            VkImageViewCreateInfo info = void;
            info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            info.image = swapImages[i];
            info.viewType = VK_IMAGE_VIEW_TYPE_2D;
            info.format = swapFormat;
            info.components = VkComponentMapping(
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY);
            info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            info.subresourceRange.baseMipLevel = 0;
            info.subresourceRange.levelCount = 1;
            info.subresourceRange.baseArrayLayer = 0;
            info.subresourceRange.layerCount = 1;
            enforce(vkCreateImageView(device, &info, null, &swapImageViews[i]) == VK_SUCCESS,
                "Failed to create swapchain image view");
        }
    }

    void createRenderPass() {
        VkAttachmentDescription color = void;
        color.format = swapFormat;
        color.samples = VK_SAMPLE_COUNT_1_BIT;
        color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        VkAttachmentReference colorRef;
        colorRef.attachment = 0;
        colorRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        VkSubpassDescription subpass = void;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorRef;

        VkSubpassDependency dep = void;
        dep.srcSubpass = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.srcAccessMask = 0;
        dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        VkRenderPassCreateInfo rp = void;
        rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp.attachmentCount = 1;
        rp.pAttachments = &color;
        rp.subpassCount = 1;
        rp.pSubpasses = &subpass;
        rp.dependencyCount = 1;
        rp.pDependencies = &dep;

        enforce(vkCreateRenderPass(device, &rp, null, &renderPass) == VK_SUCCESS,
            "Failed to create render pass");
    }

    void createFramebuffers() {
        swapFramebuffers.length = swapImageViews.length;
        for (size_t i = 0; i < swapImageViews.length; ++i) {
            VkImageView attachment = swapImageViews[i];
            VkFramebufferCreateInfo info = void;
            info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            info.renderPass = renderPass;
            info.attachmentCount = 1;
            info.pAttachments = &attachment;
            info.width = swapExtent.width;
            info.height = swapExtent.height;
            info.layers = 1;
            enforce(vkCreateFramebuffer(device, &info, null, &swapFramebuffers[i]) == VK_SUCCESS,
                "Failed to create framebuffer");
        }
    }

    VkRenderPass createOffscreenRenderPass(bool clear) {
        VkAttachmentDescription[4] attachments;
        foreach (i; 0 .. 3) {
            attachments[i] = VkAttachmentDescription.init;
            attachments[i].format = VK_FORMAT_R8G8B8A8_UNORM;
            attachments[i].samples = VK_SAMPLE_COUNT_1_BIT;
            attachments[i].loadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
            attachments[i].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
            attachments[i].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            attachments[i].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
            attachments[i].initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            attachments[i].finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        }
        VkAttachmentDescription depth = void;
        depth.format = VK_FORMAT_D24_UNORM_S8_UINT;
        depth.samples = VK_SAMPLE_COUNT_1_BIT;
        depth.loadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
        depth.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth.stencilLoadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
        depth.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth.initialLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depth.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        VkAttachmentReference[3] colorRefs;
        colorRefs[0] = VkAttachmentReference(0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        colorRefs[1] = VkAttachmentReference(1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        colorRefs[2] = VkAttachmentReference(2, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        VkAttachmentReference depthRef = VkAttachmentReference(3, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);

        VkSubpassDescription subpass = void;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 3;
        subpass.pColorAttachments = colorRefs.ptr;
        subpass.pDepthStencilAttachment = &depthRef;

        VkSubpassDependency dep = void;
        dep.srcSubpass = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dep.srcAccessMask = 0;
        dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        VkAttachmentDescription[4] allAttachments = [attachments[0], attachments[1], attachments[2], depth];
        VkRenderPassCreateInfo rp = void;
        rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp.attachmentCount = 4;
        rp.pAttachments = allAttachments.ptr;
        rp.subpassCount = 1;
        rp.pSubpasses = &subpass;
        rp.dependencyCount = 1;
        rp.pDependencies = &dep;

        VkRenderPass created;
        enforce(vkCreateRenderPass(device, &rp, null, &created) == VK_SUCCESS,
            "Failed to create offscreen render pass");
        return created;
    }

    void createOffscreenFramebuffer() {
        VkImageView[4] views = [mainAlbedo.view, mainEmissive.view, mainBump.view, mainDepth.view];
        VkFramebufferCreateInfo info = void;
        info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        info.renderPass = offscreenRenderPass;
        info.attachmentCount = 4;
        info.pAttachments = views.ptr;
        info.width = swapExtent.width;
        info.height = swapExtent.height;
        info.layers = 1;
        enforce(vkCreateFramebuffer(device, &info, null, &offscreenFramebuffer) == VK_SUCCESS,
            "Failed to create offscreen framebuffer");
    }

    void createDescriptorPoolAndSet() {
        VkDescriptorPoolSize[2] pools;
        pools[0] = VkDescriptorPoolSize(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2);
        pools[1] = VkDescriptorPoolSize(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 3);

        VkDescriptorPoolCreateInfo poolInfo = void;
        poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        poolInfo.maxSets = 1;
        poolInfo.poolSizeCount = 2;
        poolInfo.pPoolSizes = pools.ptr;
        if (descriptorPool !is null) {
            vkDestroyDescriptorPool(device, descriptorPool, null);
            descriptorPool = null;
        }
        enforce(vkCreateDescriptorPool(device, &poolInfo, null, &descriptorPool) == VK_SUCCESS,
            "Failed to create descriptor pool");

        VkDescriptorSetAllocateInfo alloc = void;
        alloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc.descriptorPool = descriptorPool;
        alloc.descriptorSetCount = 1;
        alloc.pSetLayouts = &descriptorSetLayout;
        enforce(vkAllocateDescriptorSets(device, &alloc, &descriptorSet) == VK_SUCCESS,
            "Failed to allocate descriptor set");

        destroyBuffer(globalsUbo);
        destroyBuffer(paramsUbo);
        globalsUbo = createBuffer(globalsSize(), VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        paramsUbo = createBuffer(paramsSize(), VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

        VkDescriptorBufferInfo globalsInfo = void;
        globalsInfo.buffer = globalsUbo.buffer;
        globalsInfo.offset = 0;
        globalsInfo.range = globalsUbo.size;

        VkDescriptorBufferInfo paramsInfo = void;
        paramsInfo.buffer = paramsUbo.buffer;
        paramsInfo.offset = 0;
        paramsInfo.range = paramsUbo.size;

        VkWriteDescriptorSet[2] writes;
        writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = descriptorSet;
        writes[0].dstBinding = 0;
        writes[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        writes[0].descriptorCount = 1;
        writes[0].pBufferInfo = &globalsInfo;

        writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = descriptorSet;
        writes[1].dstBinding = 4;
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        writes[1].descriptorCount = 1;
        writes[1].pBufferInfo = &paramsInfo;

        vkUpdateDescriptorSets(device, 2, writes.ptr, 0, null);
        createCompositeBuffers();
    }

    void uploadBufferData(ref Buffer gpu, float[] data) {
        if (data.length == 0) return;
        size_t sz = data.length * float.sizeof;
        if (gpu.buffer is null || gpu.size < sz) {
            destroyBuffer(gpu);
            gpu = createBuffer(sz,
                VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        }

        Buffer staging = createBuffer(sz,
            VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);
        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto dst = cast(float*)mapped;
        dst[0 .. data.length] = data[];
        vkUnmapMemory(device, staging.memory);
        copyBuffer(staging, gpu, sz);
    }

    void createCompositeBuffers() {
        destroyBuffer(compositePosBuffer);
        destroyBuffer(compositeUvBuffer);
        destroyBuffer(quadDeformBuffer);
        // Fullscreen quad positions (NDC) and UVs
        float[12] positions = [
            -1, -1,
            1, -1,
            -1, 1,
            1, 1,
            -1, 1,
            1, -1,
        ];
        float[12] uvs = [
            0, 0,
            1, 0,
            0, 1,
            1, 1,
            0, 1,
            1, 0,
        ];
        float[12] zeroDeform = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        uploadBufferData(compositePosBuffer, positions[]);
        uploadBufferData(compositeUvBuffer, uvs[]);
        uploadBufferData(quadDeformBuffer, zeroDeform[]);
    }

    void createOffscreenTargets() {
        destroyImage(mainAlbedo);
        destroyImage(mainEmissive);
        destroyImage(mainBump);
        destroyImage(mainDepth);
        if (offscreenFramebuffer !is null) {
            vkDestroyFramebuffer(device, offscreenFramebuffer, null);
            offscreenFramebuffer = null;
        }
        if (offscreenRenderPass !is null) {
            vkDestroyRenderPass(device, offscreenRenderPass, null);
            offscreenRenderPass = null;
        }

        auto extent = swapExtent;
        mainAlbedo = createImage(extent, VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            VK_IMAGE_ASPECT_COLOR_BIT, 1);
        mainEmissive = createImage(extent, VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            VK_IMAGE_ASPECT_COLOR_BIT, 1);
        mainBump = createImage(extent, VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            VK_IMAGE_ASPECT_COLOR_BIT, 1);
        mainDepth = createImage(extent, VK_FORMAT_D24_UNORM_S8_UINT,
            VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT, 1);

        offscreenRenderPass = createOffscreenRenderPass(true);
        offscreenRenderPassLoad = createOffscreenRenderPass(false);
        createOffscreenFramebuffer();
    }

    GpuImage createImage(VkExtent2D extent, VkFormat format, VkImageUsageFlags usage, VkImageAspectFlags aspect, uint mipLevels) {
        GpuImage img;
        img.format = format;
        img.extent = extent;
        img.aspect = aspect;
        img.mipLevels = mipLevels > 0 ? mipLevels : 1;

        VkImageCreateInfo ci = void;
        ci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ci.imageType = VK_IMAGE_TYPE_2D;
        ci.extent = VkExtent3D(extent.width, extent.height, 1);
        ci.mipLevels = img.mipLevels;
        ci.arrayLayers = 1;
        ci.format = format;
        ci.tiling = VK_IMAGE_TILING_OPTIMAL;
        ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        ci.usage = usage;
        ci.samples = VK_SAMPLE_COUNT_1_BIT;
        ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

        enforce(vkCreateImage(device, &ci, null, &img.image) == VK_SUCCESS,
            "Failed to create image");

        VkMemoryRequirements req = void;
        vkGetImageMemoryRequirements(device, img.image, &req);

        VkMemoryAllocateInfo alloc = void;
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.allocationSize = req.size;
        alloc.memoryTypeIndex = findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        enforce(vkAllocateMemory(device, &alloc, null, &img.memory) == VK_SUCCESS,
            "Failed to allocate image memory");
        vkBindImageMemory(device, img.image, img.memory, 0);

        VkImageViewCreateInfo view = void;
        view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = img.image;
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = format;
        view.subresourceRange.aspectMask = aspect;
        view.subresourceRange.baseMipLevel = 0;
        view.subresourceRange.levelCount = img.mipLevels;
        view.subresourceRange.baseArrayLayer = 0;
        view.subresourceRange.layerCount = 1;
        enforce(vkCreateImageView(device, &view, null, &img.view) == VK_SUCCESS,
            "Failed to create image view");

        transitionImageLayout(img.image, format, VK_IMAGE_LAYOUT_UNDEFINED,
            (aspect & VK_IMAGE_ASPECT_DEPTH_BIT) ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                                                 : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            aspect, img.mipLevels);
        return img;
    }

    void destroyImage(ref GpuImage img) {
        if (img.view !is null) {
            vkDestroyImageView(device, img.view, null);
            img.view = null;
        }
        if (img.image !is null) {
            vkDestroyImage(device, img.image, null);
            img.image = null;
        }
        if (img.memory !is null) {
            vkFreeMemory(device, img.memory, null);
            img.memory = null;
        }
    }

    uint findMemoryType(uint typeFilter, VkMemoryPropertyFlags properties) {
        VkPhysicalDeviceMemoryProperties memProps = void;
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProps);
        foreach (i; 0 .. memProps.memoryTypeCount) {
            if ((typeFilter & (1u << i)) &&
                (memProps.memoryTypes[i].propertyFlags & properties) == properties) {
                return i;
            }
        }
        enforce(false, "Suitable memory type not found");
        return 0;
    }

    Buffer createBuffer(size_t size, VkBufferUsageFlags usage, VkMemoryPropertyFlags properties) {
        Buffer buf;
        buf.size = size;
        VkBufferCreateInfo info = void;
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        enforce(vkCreateBuffer(device, &info, null, &buf.buffer) == VK_SUCCESS,
            "Failed to create buffer");
        VkMemoryRequirements req = void;
        vkGetBufferMemoryRequirements(device, buf.buffer, &req);
        VkMemoryAllocateInfo alloc = void;
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.allocationSize = req.size;
        alloc.memoryTypeIndex = findMemoryType(req.memoryTypeBits, properties);
        enforce(vkAllocateMemory(device, &alloc, null, &buf.memory) == VK_SUCCESS,
            "Failed to allocate buffer memory");
        vkBindBufferMemory(device, buf.buffer, buf.memory, 0);
        return buf;
    }

    void copyBuffer(Buffer src, Buffer dst, size_t size) {
        auto cmd = beginSingleTimeCommands();
        VkBufferCopy region = void;
        region.srcOffset = 0;
        region.dstOffset = 0;
        region.size = size;
        vkCmdCopyBuffer(cmd, src.buffer, dst.buffer, 1, &region);
        endSingleTimeCommands(cmd);
    }

    void destroyBuffer(ref Buffer buf) {
        if (buf.buffer !is null) {
            vkDestroyBuffer(device, buf.buffer, null);
            buf.buffer = null;
        }
        if (buf.memory !is null) {
            vkFreeMemory(device, buf.memory, null);
            buf.memory = null;
        }
        buf.size = 0;
    }

    void copyBufferToImage(Buffer src, VkImage dst, uint width, uint height) {
        auto cmd = beginSingleTimeCommands();
        VkBufferImageCopy region = void;
        region.bufferOffset = 0;
        region.bufferRowLength = 0;
        region.bufferImageHeight = 0;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;
        region.imageOffset = VkOffset3D(0, 0, 0);
        region.imageExtent = VkExtent3D(width, height, 1);
        vkCmdCopyBufferToImage(cmd, src.buffer, dst, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        endSingleTimeCommands(cmd);
    }

    VkCommandBuffer beginSingleTimeCommands() {
        VkCommandBufferAllocateInfo alloc = void;
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.commandPool = commandPool;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = 1;
        VkCommandBuffer cmd;
        enforce(vkAllocateCommandBuffers(device, &alloc, &cmd) == VK_SUCCESS,
            "Failed to allocate command buffer");

        VkCommandBufferBeginInfo begin = void;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(cmd, &begin);
        return cmd;
    }

    void endSingleTimeCommands(VkCommandBuffer cmd) {
        vkEndCommandBuffer(cmd);
        VkSubmitInfo submit = void;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        vkQueueSubmit(graphicsQueue, 1, &submit, VK_NULL_HANDLE);
        vkQueueWaitIdle(graphicsQueue);
        vkFreeCommandBuffers(device, commandPool, 1, &cmd);
    }

    void transitionImageLayout(VkImage image, VkFormat format, VkImageLayout oldLayout, VkImageLayout newLayout, VkImageAspectFlags aspect, uint levelCount = 1) {
        auto cmd = beginSingleTimeCommands();
        recordTransition(cmd, image, oldLayout, newLayout, aspect, levelCount);
        endSingleTimeCommands(cmd);
    }

    void createDescriptorSetLayout() {
        VkDescriptorSetLayoutBinding[5] bindings;
        bindings[0].binding = 0;
        bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;

        bindings[1].binding = 1;
        bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

        bindings[2].binding = 2;
        bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[2].descriptorCount = 1;
        bindings[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

        bindings[3].binding = 3;
        bindings[3].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[3].descriptorCount = 1;
        bindings[3].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

        bindings[4].binding = 4;
        bindings[4].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[4].descriptorCount = 1;
        bindings[4].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

        VkDescriptorSetLayoutCreateInfo info = void;
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        info.bindingCount = 5;
        info.pBindings = bindings.ptr;
        enforce(vkCreateDescriptorSetLayout(device, &info, null, &descriptorSetLayout) == VK_SUCCESS,
            "Failed to create descriptor set layout");
    }

    void createPipelineLayout() {
        VkPipelineLayoutCreateInfo info = void;
        info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        info.setLayoutCount = 1;
        info.pSetLayouts = &descriptorSetLayout;
        enforce(vkCreatePipelineLayout(device, &info, null, &pipelineLayout) == VK_SUCCESS,
            "Failed to create pipeline layout");
    }

    void fillBlendAttachment(ref VkPipelineColorBlendAttachmentState att) {
        att = VkPipelineColorBlendAttachmentState.init;
        att.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        att.blendEnable = VK_TRUE;
        auto setEq = (VkBlendOp op) {
            att.colorBlendOp = op;
            att.alphaBlendOp = op;
        };
        auto setFactor = (VkBlendFactor src, VkBlendFactor dst) {
            att.srcColorBlendFactor = src;
            att.dstColorBlendFactor = dst;
            att.srcAlphaBlendFactor = src;
            att.dstAlphaBlendFactor = dst;
        };
        switch (currentBlendMode) {
            case BlendMode.Normal:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA); break;
            case BlendMode.Multiply:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA); break;
            case BlendMode.Screen:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR); break;
            case BlendMode.Lighten:
                setEq(VK_BLEND_OP_MAX); setFactor(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE); break;
            case BlendMode.ColorDodge:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE); break;
            case BlendMode.LinearDodge:
            case BlendMode.AddGlow:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE); break;
            case BlendMode.Subtract:
                setEq(VK_BLEND_OP_REVERSE_SUBTRACT); setFactor(VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_ONE); break;
            case BlendMode.Exclusion:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR); break;
            case BlendMode.DestinationIn:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_SRC_ALPHA); break;
            case BlendMode.ClipToLower:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_DST_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA); break;
            case BlendMode.SliceFromLower:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA); break;
            default:
                setEq(VK_BLEND_OP_ADD); setFactor(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA); break;
        }
    }

    void createBasicPipeline(bool enableStencilTest, ref VkPipeline pipelineTarget) {
        if (offscreenRenderPass is null || pipelineLayout is null) return;
        enum string basicVertSrc = import("vulkan/basic/basic.vert");
        enum string basicFragSrc = import("vulkan/basic/basic.frag");
        auto vertSpv = compileGlslToSpirv("basic.vert", basicVertSrc, ".vert");
        auto fragSpv = compileGlslToSpirv("basic.frag", basicFragSrc, ".frag");
        auto vertModule = createShaderModule(vertSpv);
        auto fragModule = createShaderModule(fragSpv);
        scope (exit) {
            vkDestroyShaderModule(device, vertModule, null);
            vkDestroyShaderModule(device, fragModule, null);
        }

        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragModule;
        stages[1].pName = "main".ptr;

        VkVertexInputBindingDescription[3] bindings;
        bindings[0].binding = 0; bindings[0].stride = float.sizeof * 2; bindings[0].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        bindings[1].binding = 1; bindings[1].stride = float.sizeof * 2; bindings[1].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        bindings[2].binding = 2; bindings[2].stride = float.sizeof * 2; bindings[2].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

        VkVertexInputAttributeDescription[6] attrs;
        attrs[0] = VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32_SFLOAT, 0);
        attrs[1] = VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32_SFLOAT, 4);
        attrs[2] = VkVertexInputAttributeDescription(2, 1, VK_FORMAT_R32_SFLOAT, 0);
        attrs[3] = VkVertexInputAttributeDescription(3, 1, VK_FORMAT_R32_SFLOAT, 4);
        attrs[4] = VkVertexInputAttributeDescription(4, 2, VK_FORMAT_R32_SFLOAT, 0);
        attrs[5] = VkVertexInputAttributeDescription(5, 2, VK_FORMAT_R32_SFLOAT, 4);

        VkPipelineVertexInputStateCreateInfo vi = void;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = 3;
        vi.pVertexBindingDescriptions = bindings.ptr;
        vi.vertexAttributeDescriptionCount = 6;
        vi.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia = void;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        ia.primitiveRestartEnable = VK_FALSE;

        VkPipelineViewportStateCreateInfo vp = void;
        vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1;
        vp.scissorCount = 1;

        VkDynamicState[5] dynStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
            VK_DYNAMIC_STATE_STENCIL_REFERENCE,
            VK_DYNAMIC_STATE_STENCIL_WRITE_MASK,
            VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK
        ];
        VkPipelineDynamicStateCreateInfo dyn = void;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkPipelineRasterizationStateCreateInfo rs = void;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.depthClampEnable = VK_FALSE;
        rs.rasterizerDiscardEnable = VK_FALSE;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.depthBiasEnable = VK_FALSE;

        VkPipelineMultisampleStateCreateInfo ms = void;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState[3] blendAtt;
        foreach (i; 0 .. 3) {
            blendAtt[i] = VkPipelineColorBlendAttachmentState.init;
            fillBlendAttachment(blendAtt[i]);
        }
        VkPipelineColorBlendStateCreateInfo blend = void;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 3;
        blend.pAttachments = blendAtt.ptr;

        VkPipelineDepthStencilStateCreateInfo ds = void;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_TRUE;
        ds.depthWriteEnable = VK_TRUE;
        ds.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
        ds.depthBoundsTestEnable = VK_FALSE;
        ds.stencilTestEnable = enableStencilTest ? VK_TRUE : VK_FALSE;
        ds.front = VkStencilOpState(VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
            enableStencilTest ? VK_COMPARE_OP_EQUAL : VK_COMPARE_OP_ALWAYS, 0xFF, 0xFF, 1);
        ds.back = ds.front;

        VkGraphicsPipelineCreateInfo gp = void;
        gp.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        gp.stageCount = 2;
        gp.pStages = stages.ptr;
        gp.pVertexInputState = &vi;
        gp.pInputAssemblyState = &ia;
        gp.pViewportState = &vp;
        gp.pRasterizationState = &rs;
        gp.pMultisampleState = &ms;
        gp.pDepthStencilState = &ds;
        gp.pColorBlendState = &blend;
        gp.pDynamicState = &dyn;
        gp.layout = pipelineLayout;
        gp.renderPass = offscreenRenderPass;
        gp.subpass = 0;

        if (pipelineTarget !is null) {
            vkDestroyPipeline(device, pipelineTarget, null);
            pipelineTarget = null;
        }

        enforce(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gp, null, &pipelineTarget) == VK_SUCCESS,
            "Failed to create basic pipeline");
    }

    void createMaskPipeline() {
        if (offscreenRenderPass is null || pipelineLayout is null) return;
        enum string vertSrc = import("vulkan/mask.vert");
        enum string fragSrc = import("vulkan/mask.frag");
        auto vertSpv = compileGlslToSpirv("mask.vert", vertSrc, ".vert");
        auto fragSpv = compileGlslToSpirv("mask.frag", fragSrc, ".frag");
        auto vertModule = createShaderModule(vertSpv);
        auto fragModule = createShaderModule(fragSpv);
        scope (exit) {
            vkDestroyShaderModule(device, vertModule, null);
            vkDestroyShaderModule(device, fragModule, null);
        }

        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragModule;
        stages[1].pName = "main".ptr;

        VkVertexInputBindingDescription[2] bindings;
        bindings[0].binding = 0; bindings[0].stride = float.sizeof * 2; bindings[0].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        bindings[1].binding = 2; bindings[1].stride = float.sizeof * 2; bindings[1].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

        VkVertexInputAttributeDescription[4] attrs;
        attrs[0] = VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32_SFLOAT, 0);
        attrs[1] = VkVertexInputAttributeDescription(1, 0, VK_FORMAT_R32_SFLOAT, 4);
        attrs[2] = VkVertexInputAttributeDescription(2, 2, VK_FORMAT_R32_SFLOAT, 0);
        attrs[3] = VkVertexInputAttributeDescription(3, 2, VK_FORMAT_R32_SFLOAT, 4);

        VkPipelineVertexInputStateCreateInfo vi = void;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = 2;
        vi.pVertexBindingDescriptions = bindings.ptr;
        vi.vertexAttributeDescriptionCount = 4;
        vi.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia = void;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        ia.primitiveRestartEnable = VK_FALSE;

        VkPipelineViewportStateCreateInfo vp = void;
        vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1;
        vp.scissorCount = 1;

        VkDynamicState[5] dynStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
            VK_DYNAMIC_STATE_STENCIL_REFERENCE,
            VK_DYNAMIC_STATE_STENCIL_WRITE_MASK,
            VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK
        ];
        VkPipelineDynamicStateCreateInfo dyn = void;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkPipelineRasterizationStateCreateInfo rs = void;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

        VkPipelineMultisampleStateCreateInfo ms = void;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState[3] blendAtt;
        foreach (i; 0 .. 3) {
            blendAtt[i] = VkPipelineColorBlendAttachmentState.init;
            blendAtt[i].colorWriteMask = 0; // Mask writes only touch stencil
            blendAtt[i].blendEnable = VK_FALSE;
        }
        VkPipelineColorBlendStateCreateInfo blend = void;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 3;
        blend.pAttachments = blendAtt.ptr;

        VkPipelineDepthStencilStateCreateInfo ds = void;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        ds.depthCompareOp = VK_COMPARE_OP_ALWAYS;
        ds.stencilTestEnable = VK_TRUE;
        ds.front = VkStencilOpState(VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_REPLACE,
            VK_COMPARE_OP_ALWAYS, 0xFF, 0xFF, 1);
        ds.back = ds.front;

        VkGraphicsPipelineCreateInfo gp = void;
        gp.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        gp.stageCount = 2;
        gp.pStages = stages.ptr;
        gp.pVertexInputState = &vi;
        gp.pInputAssemblyState = &ia;
        gp.pViewportState = &vp;
        gp.pRasterizationState = &rs;
        gp.pMultisampleState = &ms;
        gp.pDepthStencilState = &ds;
        gp.pColorBlendState = &blend;
        gp.pDynamicState = &dyn;
        gp.layout = pipelineLayout;
        gp.renderPass = offscreenRenderPass;
        gp.subpass = 0;

        if (maskPipeline !is null) {
            vkDestroyPipeline(device, maskPipeline, null);
            maskPipeline = null;
        }
        enforce(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gp, null, &maskPipeline) == VK_SUCCESS,
            "Failed to create mask pipeline");
    }

    void createCompositePipeline(bool enableStencilTest, ref VkPipeline pipelineTarget) {
        if (offscreenRenderPass is null || pipelineLayout is null) return;
        enum string vertSrc = import("vulkan/basic/composite.vert");
        enum string fragSrc = import("vulkan/basic/composite.frag");
        auto vertSpv = compileGlslToSpirv("composite.vert", vertSrc, ".vert");
        auto fragSpv = compileGlslToSpirv("composite.frag", fragSrc, ".frag");
        auto vertModule = createShaderModule(vertSpv);
        auto fragModule = createShaderModule(fragSpv);
        scope (exit) {
            vkDestroyShaderModule(device, vertModule, null);
            vkDestroyShaderModule(device, fragModule, null);
        }

        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertModule;
        stages[0].pName = "main".ptr;
        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragModule;
        stages[1].pName = "main".ptr;

        VkVertexInputBindingDescription[2] bindings;
        bindings[0].binding = 0; bindings[0].stride = float.sizeof * 2; bindings[0].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        bindings[1].binding = 1; bindings[1].stride = float.sizeof * 2; bindings[1].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

        VkVertexInputAttributeDescription[4] attrs;
        attrs[0] = VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32G32_SFLOAT, 0);
        attrs[1] = VkVertexInputAttributeDescription(1, 1, VK_FORMAT_R32G32_SFLOAT, 0);

        VkPipelineVertexInputStateCreateInfo vi = void;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = 2;
        vi.pVertexBindingDescriptions = bindings.ptr;
        vi.vertexAttributeDescriptionCount = 2;
        vi.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia = void;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        ia.primitiveRestartEnable = VK_FALSE;

        VkPipelineViewportStateCreateInfo vp = void;
        vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1;
        vp.scissorCount = 1;

        VkDynamicState[5] dynStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
            VK_DYNAMIC_STATE_STENCIL_REFERENCE,
            VK_DYNAMIC_STATE_STENCIL_WRITE_MASK,
            VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK
        ];
        VkPipelineDynamicStateCreateInfo dyn = void;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkPipelineRasterizationStateCreateInfo rs = void;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

        VkPipelineMultisampleStateCreateInfo ms = void;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState[3] blendAtt;
        foreach (i; 0 .. 3) {
            blendAtt[i] = VkPipelineColorBlendAttachmentState.init;
            fillBlendAttachment(blendAtt[i]);
        }
        VkPipelineColorBlendStateCreateInfo blend = void;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 3;
        blend.pAttachments = blendAtt.ptr;

        VkPipelineDepthStencilStateCreateInfo ds = void;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        ds.stencilTestEnable = enableStencilTest ? VK_TRUE : VK_FALSE;
        ds.front = VkStencilOpState(VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
            enableStencilTest ? VK_COMPARE_OP_EQUAL : VK_COMPARE_OP_ALWAYS, 0xFF, 0xFF, 1);
        ds.back = ds.front;

        VkGraphicsPipelineCreateInfo gp = void;
        gp.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        gp.stageCount = 2;
        gp.pStages = stages.ptr;
        gp.pVertexInputState = &vi;
        gp.pInputAssemblyState = &ia;
        gp.pViewportState = &vp;
        gp.pRasterizationState = &rs;
        gp.pMultisampleState = &ms;
        gp.pDepthStencilState = &ds;
        gp.pColorBlendState = &blend;
        gp.pDynamicState = &dyn;
        gp.layout = pipelineLayout;
        gp.renderPass = offscreenRenderPass;
        gp.subpass = 0;

        if (pipelineTarget !is null) {
            vkDestroyPipeline(device, pipelineTarget, null);
            pipelineTarget = null;
        }
        enforce(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gp, null, &pipelineTarget) == VK_SUCCESS,
            "Failed to create composite pipeline");
    }

    void recreatePipelines() {
        createBasicPipeline(false, basicPipeline);
        createBasicPipeline(true, basicMaskedPipeline);
        createMaskPipeline();
        createCompositePipeline(false, compositePipeline);
        createCompositePipeline(true, compositeMaskedPipeline);
    }

    size_t pixelSizeForFormat(VkFormat format) {
        switch (format) {
            case VK_FORMAT_R8_UNORM: return 1;
            case VK_FORMAT_R8G8B8A8_UNORM: return 4;
            case VK_FORMAT_D24_UNORM_S8_UINT: return 4;
            default: enforce(false, "Unsupported format for pixel size"); return 0;
        }
    }

    VkSamplerAddressMode wrapToAddress(Wrapping wrapping) {
        switch (wrapping) {
            case Wrapping.Clamp: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            case Wrapping.Repeat: return VK_SAMPLER_ADDRESS_MODE_REPEAT;
            case Wrapping.Mirror: return VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
            default: break;
        }
        return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    }

    VkFilter filteringToFilter(Filtering filtering) {
        switch (filtering) {
            case Filtering.Linear: return VK_FILTER_LINEAR;
            case Filtering.Point: return VK_FILTER_NEAREST;
            default: break;
        }
        return VK_FILTER_LINEAR;
    }

    void recreateSampler(VkTextureHandle handle) {
        if (handle.sampler !is null) {
            vkDestroySampler(device, handle.sampler, null);
            handle.sampler = null;
        }
        VkSamplerCreateInfo samplerInfo = void;
        samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        samplerInfo.magFilter = filteringToFilter(handle.filtering);
        samplerInfo.minFilter = filteringToFilter(handle.filtering);
        auto address = wrapToAddress(handle.wrapping);
        samplerInfo.addressModeU = address;
        samplerInfo.addressModeV = address;
        samplerInfo.addressModeW = address;
        samplerInfo.anisotropyEnable = supportsAnisotropy && handle.anisotropy > 1.0f;
        samplerInfo.maxAnisotropy = samplerInfo.anisotropyEnable ? (handle.anisotropy > maxSupportedAnisotropy ? maxSupportedAnisotropy : handle.anisotropy) : 1.0f;
        samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
        samplerInfo.unnormalizedCoordinates = VK_FALSE;
        samplerInfo.compareEnable = VK_FALSE;
        samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
        samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        samplerInfo.mipLodBias = 0.0f;
        samplerInfo.minLod = 0.0f;
        samplerInfo.maxLod = cast(float)(handle.mipLevels > 0 ? handle.mipLevels - 1 : 0);
        enforce(vkCreateSampler(device, &samplerInfo, null, &handle.sampler) == VK_SUCCESS,
            "Failed to create sampler");
    }

    void recordTransition(VkCommandBuffer cmd, VkImage image, VkImageLayout oldLayout, VkImageLayout newLayout, VkImageAspectFlags aspect, uint levelCount = 1) {
        VkImageMemoryBarrier barrier = void;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = oldLayout;
        barrier.newLayout = newLayout;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = aspect;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = levelCount;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        VkPipelineStageFlags srcStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        VkPipelineStageFlags dstStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        vkCmdPipelineBarrier(
            cmd,
            srcStage, dstStage,
            0,
            0, null,
            0, null,
            1, &barrier);
    }

    size_t globalsSize() { return GlobalsData.sizeof; }
    size_t paramsSize() { return ParamsData.sizeof; }

    void updateGlobalsUBO(ref GlobalsData data) {
        if (globalsUbo.buffer is null) return;
        writeBuffer(globalsUbo, (cast(ubyte*)&data)[0 .. GlobalsData.sizeof]);
    }

    void updateParamsUBO(ref ParamsData data) {
        if (paramsUbo.buffer is null) return;
        writeBuffer(paramsUbo, (cast(ubyte*)&data)[0 .. ParamsData.sizeof]);
    }

    void writeBuffer(ref Buffer buf, const(ubyte)[] bytes) {
        if (buf.buffer is null || buf.memory is null) return;
        void* mapped;
        vkMapMemory(device, buf.memory, 0, buf.size, 0, &mapped);
        auto dst = cast(ubyte*)mapped;
        auto copyLen = bytes.length < buf.size ? bytes.length : buf.size;
        dst[0 .. copyLen] = bytes[0 .. copyLen];
        if (copyLen < buf.size) dst[copyLen .. buf.size] = 0;
        vkUnmapMemory(device, buf.memory);
    }

    VkShaderModule createShaderModule(const(ubyte)[] spirv) {
        VkShaderModuleCreateInfo info = void;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = spirv.length;
        info.pCode = cast(uint*)spirv.ptr;
        VkShaderModule handle;
        enforce(vkCreateShaderModule(device, &info, null, &handle) == VK_SUCCESS,
            "Failed to create shader module");
        return handle;
    }

    const(ubyte)[] compileGlslToSpirv(string logicalName, string source, string stageExt) {
        import std.file : tempDir, exists, read, write;
        import std.path : buildPath, dirName, absolutePath, baseName;
        import std.uuid : randomUUID;
        import std.process : execute;

        // Prefer precompiled .spv if present (no glslc requirement).
        string[] candidates;
        candidates ~= buildPath("shaders", "vulkan", "compiled", logicalName ~ ".spv");
        candidates ~= buildPath("shaders", "vulkan", logicalName ~ ".spv");
        candidates ~= logicalName.endsWith(".spv") ? logicalName : logicalName ~ ".spv";
        foreach (path; candidates) {
            if (exists(path)) {
                auto bytes = read(path);
                enforce(bytes.length > 0, "Precompiled SPIR-V is empty: "~path);
                return cast(const(ubyte)[])bytes;
            }
        }

        // Fallback to glslc if available.
        enforce(glslcPath.length > 0, "glslc not found. Provide precompiled SPIR-V at shaders/vulkan/compiled/"~logicalName~".spv");
        auto base = randomUUID().toString();
        auto srcPath = buildPath(tempDir(), base ~ stageExt ~ ".glsl");
        auto spvPath = buildPath(tempDir(), base ~ stageExt ~ ".spv");
        scope (exit) {
            import std.file : remove;
            if (exists(srcPath)) remove(srcPath);
            if (exists(spvPath)) remove(spvPath);
        }
        write(srcPath, source);
        auto result = execute([glslcPath, "-o", spvPath, "-fshader-stage="~(stageExt[1..$]), srcPath]);
        enforce(result.status == 0, "glslc failed: "~result.output);
        auto bytes = read(spvPath);
        return cast(const(ubyte)[])bytes;
    }

    void detectGlslc() {
        import std.process : executeShell;
        auto res = executeShell("which glslc");
        if (res.status == 0 && res.output.length) {
            glslcPath = res.output.strip();
        } else {
            glslcPath = "";
        }
    }

    void shutdown() {
        foreach (i; 0 .. maxFramesInFlight) {
            if (i < inFlightFences.length && inFlightFences[i] !is null) {
                vkDestroyFence(device, inFlightFences[i], null);
                inFlightFences[i] = null;
            }
        }
        if (renderFinished !is null) {
            vkDestroySemaphore(device, renderFinished, null);
            renderFinished = null;
        }
        if (imageAvailable !is null) {
            vkDestroySemaphore(device, imageAvailable, null);
            imageAvailable = null;
        }
        foreach (fb; swapFramebuffers) {
            if (fb !is null) vkDestroyFramebuffer(device, fb, null);
        }
        swapFramebuffers.length = 0;
        if (renderPass !is null) {
            vkDestroyRenderPass(device, renderPass, null);
            renderPass = null;
        }
        if (commandPool !is null) {
            vkDestroyCommandPool(device, commandPool, null);
            commandPool = null;
        }
        if (swapchain !is null) {
            vkDestroySwapchainKHR(device, swapchain, null);
            swapchain = null;
        }
        foreach (view; swapImageViews) {
            if (view !is null) vkDestroyImageView(device, view, null);
        }
        swapImageViews.length = 0;
        destroyImage(mainAlbedo);
        destroyImage(mainEmissive);
        destroyImage(mainBump);
        destroyImage(mainDepth);
        destroyImage(dynamicDummyColor);
        destroyImage(dynamicDummyDepth);
        destroyBuffer(sharedVertexBuffer);
        destroyBuffer(sharedUvBuffer);
        destroyBuffer(sharedDeformBuffer);
        destroyBuffer(compositePosBuffer);
        destroyBuffer(compositeUvBuffer);
        destroyBuffer(quadDeformBuffer);
        foreach (ref buf; indexBuffers) {
            destroyBuffer(buf);
        }
        indexBuffers.clear();
        if (basicPipeline !is null) {
            vkDestroyPipeline(device, basicPipeline, null);
            basicPipeline = null;
        }
        if (basicMaskedPipeline !is null) {
            vkDestroyPipeline(device, basicMaskedPipeline, null);
            basicMaskedPipeline = null;
        }
        if (maskPipeline !is null) {
            vkDestroyPipeline(device, maskPipeline, null);
            maskPipeline = null;
        }
        if (compositePipeline !is null) {
            vkDestroyPipeline(device, compositePipeline, null);
            compositePipeline = null;
        }
        if (compositeMaskedPipeline !is null) {
            vkDestroyPipeline(device, compositeMaskedPipeline, null);
            compositeMaskedPipeline = null;
        }
        if (descriptorPool !is null) {
            vkDestroyDescriptorPool(device, descriptorPool, null);
            descriptorPool = null;
        }
        if (pipelineLayout !is null) {
            vkDestroyPipelineLayout(device, pipelineLayout, null);
            pipelineLayout = null;
        }
        if (descriptorSetLayout !is null) {
            vkDestroyDescriptorSetLayout(device, descriptorSetLayout, null);
            descriptorSetLayout = null;
        }
        if (device !is null) {
            vkDeviceWaitIdle(device);
            vkDestroyDevice(device, null);
            device = null;
        }
        if (instance !is null) {
            vkDestroyInstance(instance, null);
            instance = null;
        }
        initialized = false;
    }
}
