module nijilive.core.render.backends.vulkan;

import std.exception : enforce;
import std.stdio : writeln, writefln;
import std.math : isFinite;
import std.string : toStringz, strip, fromStringz;
import std.algorithm : endsWith, canFind, clamp;

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
import nijilive.core.render.shared_deform_buffer : sharedVertexBufferData, sharedUvBufferData, sharedDeformBufferData,
    sharedVertexBufferDirty, sharedUvBufferDirty, sharedDeformBufferDirty,
    sharedVertexMarkUploaded, sharedUvMarkUploaded, sharedDeformMarkUploaded;

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
    bool skipRenderpassFrame = false; // デバッグ用: レンダーパスを飛ばすフレーム
    bool debugSwapPassFrame = false; // デバッグ用: スワップチェイン直接描画を行ったフレーム
    bool testMode = false; // --test モード時に簡易検証経路を使う
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
    VkPipelineLayout debugSwapPipelineLayout;
    VkPipeline debugSwapPipeline;
    VkDescriptorSetLayout descriptorSetLayout;
    VkDescriptorPool descriptorPool;
    VkDescriptorSet descriptorSet;
    string[] instanceExtensions;
    string[] deviceExtensions = ["VK_KHR_swapchain"];
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
    // 1フレーム内でのパケットboundsの統合
    vec4 frameBoundsUnion;
    bool frameBoundsUnionValid = false;
    vec4 frameBoundsUnionClip;
    bool frameBoundsUnionClipValid = false;
    Buffer debugReadbackBuffer;
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
    VkTextureHandle debugWhiteTex;
    VkTextureHandle debugBlackTex;
    Buffer[RenderResourceHandle] indexBuffers;
    Buffer compositePosBuffer;
    Buffer compositeUvBuffer;
    // Fullscreen/quad rendering uses SoA buffers to match basic pipeline layout.
    Buffer quadPosXBuffer;
    Buffer quadPosYBuffer;
    Buffer quadUvXBuffer;
    Buffer quadUvYBuffer;
    Buffer quadDeformXBuffer;
    Buffer quadDeformYBuffer;
    // デバッグ用: バッファ→イメージコピーで矩形を塗るための1ピクセルカラー
    Buffer debugRectBuffer;
    bool debugDrawBounds = true;
    bool imagesInitialized = false; // オフスクリーン画像のレイアウト初期化完了フラグ
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

    void setInstanceExtensions(string[] exts) {
        instanceExtensions = exts.dup;
    }

    void setDeviceExtensions(string[] exts) {
        deviceExtensions = exts.dup;
    }

    void setTestMode(bool v) {
        testMode = v;
    }

    VkInstance instanceHandle() {
        return instance;
    }

    VkDevice deviceHandle() {
        return device;
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
        createDebugSolidTextures();
        // 初期状態のサンプラーを白テクスチャで埋めておく
        bindTextureHandle(debugWhiteTex, 1);
        bindTextureHandle(debugWhiteTex, 2);
        bindTextureHandle(debugWhiteTex, 3);
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

        VkBufferImageCopy region = VkBufferImageCopy.init;
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
        enum bool DEBUG_SKIP_RENDERPASS = false; // レンダーパス経路を飛ばしてコピー経路のみ検証する
        // コマンドを確実に初期状態に戻す
        vkResetCommandPool(device, commandPool, 0);

        if (swapchain is null) {
            enforce(false, "Swapchain is not created. Call setSurface and resizeViewportTargets first.");
        }

        // フレーム毎のunion初期化
        frameBoundsUnionValid = false;
        frameBoundsUnion = vec4(float.nan, float.nan, float.nan, float.nan);
        frameBoundsUnionClipValid = false;
        frameBoundsUnionClip = vec4(float.nan, float.nan, float.nan, float.nan);

        VkResult acquireRes = vkAcquireNextImageKHR(device, swapchain, ulong.max, imageAvailable, VK_NULL_HANDLE, &currentImageIndex);
        if (acquireRes == VK_ERROR_OUT_OF_DATE_KHR) {
            recreateSwapchain();
            swapchainValid = false;
            return;
        }
        enforce(acquireRes == VK_SUCCESS || acquireRes == VK_SUBOPTIMAL_KHR, "Failed to acquire swapchain image");
        swapchainValid = true;

        auto cmd = frameCommands[currentFrame];
        // 再録画のたびにリセットして内容を確実に消す
        vkResetCommandBuffer(cmd, 0);
        VkCommandBufferBeginInfo beginInfo = VkCommandBufferBeginInfo.init;
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        enforce(vkBeginCommandBuffer(cmd, &beginInfo) == VK_SUCCESS,
            "Failed to begin command buffer");
        activeCommand = cmd;

        // アトラス更新があればこのタイミングでGPUに反映
        if (sharedVertexBufferDirty()) {
            uploadSharedVertexBuffer(sharedVertexBufferData());
            sharedVertexMarkUploaded();
        }
        if (sharedUvBufferDirty()) {
            uploadSharedUvBuffer(sharedUvBufferData());
            sharedUvMarkUploaded();
        }
        if (sharedDeformBufferDirty()) {
            uploadSharedDeformBuffer(sharedDeformBufferData());
            sharedDeformMarkUploaded();
        }

        enum bool DEBUG_SWAP_TRI_PASS = false;
        bool useDebugSwapPass = DEBUG_SWAP_TRI_PASS || testMode;
        if (useDebugSwapPass) {
            writefln("[VK debugSwap] using swap triangle path (testMode=%s)", testMode);
            // スワップチェインへの最小描画でパイプライン/レンダーパスを検証
            enforce(debugSwapPipeline !is null, "debug swap pipeline not created");
            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);

            VkClearValue dbgClear;
            dbgClear.color.float32 = [0.0f, 0.0f, 0.0f, 1.0f];
            VkRenderPassBeginInfo rp = VkRenderPassBeginInfo.init;
            rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            rp.renderPass = renderPass;
            rp.framebuffer = swapFramebuffers[currentImageIndex];
            rp.renderArea = VkRect2D(VkOffset2D(0, 0), swapExtent);
            rp.clearValueCount = 1;
            rp.pClearValues = &dbgClear;

            vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);
            VkViewport vp = VkViewport(0, 0, cast(float)swapExtent.width, cast(float)swapExtent.height, 0.0f, 1.0f);
            VkRect2D scissor = VkRect2D(VkOffset2D(0, 0), swapExtent);
            vkCmdSetViewport(cmd, 0, 1, &vp);
            vkCmdSetScissor(cmd, 0, 1, &scissor);
            vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, debugSwapPipeline);
            // 頂点なし（三角形）+ 四隅にインスタンス番号で色を分けて可視化
            vkCmdDraw(cmd, 3, 1, 0, 0);
            vkCmdEndRenderPass(cmd);

            // プレゼン前にサンプルを取るため TRANSFER_SRC へ遷移
            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
            const uint sampleW = 64;
            const uint sampleH = 64;
            size_t sampleSize = sampleW * sampleH * 4;
            ensureReadbackBuffer(sampleSize);
            VkBufferImageCopy copy = VkBufferImageCopy.init;
            copy.bufferOffset = 0;
            copy.bufferRowLength = 0;
            copy.bufferImageHeight = 0;
            copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            copy.imageSubresource.mipLevel = 0;
            copy.imageSubresource.baseArrayLayer = 0;
            copy.imageSubresource.layerCount = 1;
            copy.imageOffset = VkOffset3D(0, 0, 0);
            copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
            vkCmdCopyImageToBuffer(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                debugReadbackBuffer.buffer, 1, &copy);
            // 最終的にプレゼントレイアウトへ戻す
            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_ASPECT_COLOR_BIT);

            enforce(vkEndCommandBuffer(cmd) == VK_SUCCESS, "Failed to end debug swap command buffer");
            activeCommand = null;
            debugSwapPassFrame = true;
            return;
        }

        if (DEBUG_SKIP_RENDERPASS) {
            // このフレームはレンダーパスを実行せず、endSceneで単発コマンドを走らせる
            vkEndCommandBuffer(cmd);
            activeCommand = null;
            skipRenderpassFrame = true;
            return;
        }

        // 1ショットで pre-pass の書き込み経路を検証する
        // 追加の単発クリア＋コピー検証をOFFにして干渉をなくす
        enum bool DEBUG_PREPASS_SINGLESHOT = false;
        if (DEBUG_PREPASS_SINGLESHOT) {
            const uint sampleW = 64;
            const uint sampleH = 64;
            size_t sampleSize = sampleW * sampleH * 4;
            ensureReadbackBuffer(sampleSize);

            auto sCmd = beginSingleTimeCommands();
            // clear 用レイアウトへ遷移
            recordTransition(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
            VkClearColorValue dbgPre;
            dbgPre.float32 = [0.0f, 0.0f, 1.0f, 1.0f]; // blue
            VkImageSubresourceRange rngPre = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
            vkCmdClearColorImage(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &dbgPre, 1, &rngPre);
            // copy して読み出し
            recordTransition(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
            VkBufferImageCopy copy = VkBufferImageCopy.init;
            copy.bufferOffset = 0;
            copy.bufferRowLength = 0;
            copy.bufferImageHeight = 0;
            copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            copy.imageSubresource.mipLevel = 0;
            copy.imageSubresource.baseArrayLayer = 0;
            copy.imageSubresource.layerCount = 1;
            int sx = cast(int)mainAlbedo.extent.width / 2 - sampleW / 2;
            int sy = cast(int)mainAlbedo.extent.height / 2 - sampleH / 2;
            if (sx < 0) sx = 0;
            if (sy < 0) sy = 0;
            copy.imageOffset = VkOffset3D(sx, sy, 0);
            copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
            vkCmdCopyImageToBuffer(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                debugReadbackBuffer.buffer, 1, &copy);
            // color attachment に戻す
            recordTransition(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
            endSingleTimeCommands(sCmd);

            // map してログ出力
            void* ptr;
            if (vkMapMemory(device, debugReadbackBuffer.memory, 0, sampleSize, 0, &ptr) == VK_SUCCESS) {
                auto mapped = (cast(ubyte*)ptr)[0 .. sampleSize];
                ulong sumR = 0, sumG = 0, sumB = 0, sumA = 0;
                foreach (i; 0 .. sampleSize / 4) {
                    auto idx = i * 4;
                    sumR += mapped[idx + 0];
                    sumG += mapped[idx + 1];
                    sumB += mapped[idx + 2];
                    sumA += mapped[idx + 3];
                }
                double count = cast(double)(sampleSize / 4);
                writefln("[VK singleShot] avg=(%.3f, %.3f, %.3f, %.3f) first=[%s]",
                    sumR / count, sumG / count, sumB / count, sumA / count, mapped[0 .. 4]);
                vkUnmapMemory(device, debugReadbackBuffer.memory);
            }
        }

        // 明瞭な背景色（白）でデバッグしやすくする
        VkClearValue clearColor = VkClearValue.init;
        clearColor.color.float32 = [1.0f, 1.0f, 1.0f, 1.0f];

        // パス前に mainAlbedo を明示的にクリアして書き込み経路を検証
        enum bool DEBUG_PREPASS_CLEAR_IMAGE = true; // 強制クリアで書き込み経路を検証
        enum bool DEBUG_READBACK_PREPASS = true; // prepass clear後すぐに読んで経路確認
        if (DEBUG_PREPASS_CLEAR_IMAGE) {
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
            VkClearColorValue dbgPre;
            dbgPre.float32 = [0.0f, 0.0f, 1.0f, 1.0f]; // blue
            VkImageSubresourceRange rngPre = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
            vkCmdClearColorImage(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &dbgPre, 1, &rngPre);
            if (DEBUG_READBACK_PREPASS) {
                const int sampleW = 64;
                const int sampleH = 64;
                size_t sampleSize = sampleW * sampleH * 4;
                ensureReadbackBuffer(sampleSize * 2);
                VkBufferImageCopy copy = VkBufferImageCopy.init;
                copy.bufferOffset = 0;
                copy.bufferRowLength = 0;
                copy.bufferImageHeight = 0;
                copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                copy.imageSubresource.mipLevel = 0;
                copy.imageSubresource.baseArrayLayer = 0;
                copy.imageSubresource.layerCount = 1;
                int sx = cast(int)mainAlbedo.extent.width / 2 - sampleW / 2;
                int sy = cast(int)mainAlbedo.extent.height / 2 - sampleH / 2;
                if (sx < 0) sx = 0;
                if (sy < 0) sy = 0;
                copy.imageOffset = VkOffset3D(sx, sy, 0);
                copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
                recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
                vkCmdCopyImageToBuffer(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    debugReadbackBuffer.buffer, 1, &copy);
                recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
            }
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
        }

        // 一時テスト: LOAD パスで事前クリア保持を確認する（強制ONで最小経路を確認）
        enum bool USE_LOAD_RENDERPASS = false;

        // ログ: 添付ビュー/フォーマット確認
        writefln("[VK fb] offscreen views albedo=%s emissive=%s bump=%s depth=%s extent=%sx%s",
            mainAlbedo.view, mainEmissive.view, mainBump.view, mainDepth.view,
            mainAlbedo.extent.width, mainAlbedo.extent.height);

        // 事前に緑クリアして LOAD で保持するか検証
        if (USE_LOAD_RENDERPASS) {
            auto preCmd = beginSingleTimeCommands();
            recordTransition(preCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
            VkClearColorValue preClr; preClr.float32 = [0.0f, 1.0f, 0.0f, 1.0f];
            VkImageSubresourceRange preRng = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
            vkCmdClearColorImage(preCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &preClr, 1, &preRng);
            recordTransition(preCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
            endSingleTimeCommands(preCmd);
        }

        // レンダーパス前に添付レイアウトを明示的にCOLOR_ATTACHMENT/DEPTHへ
        VkImageLayout baseLayout = imagesInitialized ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
        VkImageLayout baseDepthLayout = imagesInitialized ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED;
        recordTransition(cmd, mainAlbedo.image, baseLayout, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
        recordTransition(cmd, mainEmissive.image, baseLayout, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainEmissive.aspect);
        recordTransition(cmd, mainBump.image, baseLayout, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainBump.aspect);
        recordTransition(cmd, mainDepth.image, baseDepthLayout, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, mainDepth.aspect);
        imagesInitialized = true;

        // デバッグ: レンダーパスを完全にスキップし、単発経路のみで書込み/ブリットを検証
        enum bool DEBUG_FORCE_DIRECT_SKIP = false;
        if (DEBUG_FORCE_DIRECT_SKIP) {
            vkEndCommandBuffer(cmd);
            activeCommand = null;
            skipRenderpassFrame = true;
            return;
        }

        // 付加的な単純検証: ミニコマンドバッファでclear+copyのみ行い、render pass抜きで書けるかを見る
        enum bool DEBUG_MINI_CLEAR_COPY = false;
        if (DEBUG_MINI_CLEAR_COPY) {
            const int sampleW = 64;
            const int sampleH = 64;
            size_t sampleSize = sampleW * sampleH * 4;
            ensureReadbackBuffer(sampleSize);
            auto miniCmd = beginSingleTimeCommands();
            recordTransition(miniCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
            VkClearColorValue miniClr; miniClr.float32 = [1.0f, 0.0f, 0.0f, 1.0f]; // red
            VkImageSubresourceRange miniRng = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
            vkCmdClearColorImage(miniCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &miniClr, 1, &miniRng);
            recordTransition(miniCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
            VkBufferImageCopy miniCopy = VkBufferImageCopy.init;
            miniCopy.bufferOffset = 0;
            miniCopy.bufferRowLength = 0;
            miniCopy.bufferImageHeight = 0;
            miniCopy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            miniCopy.imageSubresource.mipLevel = 0;
            miniCopy.imageSubresource.baseArrayLayer = 0;
            miniCopy.imageSubresource.layerCount = 1;
            miniCopy.imageOffset = VkOffset3D(0, 0, 0);
            miniCopy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
            vkCmdCopyImageToBuffer(miniCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, debugReadbackBuffer.buffer, 1, &miniCopy);
            recordTransition(miniCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
            endSingleTimeCommands(miniCmd);
            // マップして即ログ
            void* ptrMini;
            if (vkMapMemory(device, debugReadbackBuffer.memory, 0, sampleSize, 0, &ptrMini) == VK_SUCCESS) {
                auto mapped = (cast(ubyte*)ptrMini)[0 .. sampleSize];
                ulong sR=0,sG=0,sB=0,sA=0;
                foreach(i;0 .. sampleSize/4){
                    auto idx=i*4; sR+=mapped[idx]; sG+=mapped[idx+1]; sB+=mapped[idx+2]; sA+=mapped[idx+3];
                }
                double cnt=cast(double)(sampleSize/4);
                writefln("[VK miniClear] avg=(%.3f,%.3f,%.3f,%.3f) first=%s", sR/cnt, sG/cnt, sB/cnt, sA/cnt, mapped[0..4]);
                vkUnmapMemory(device, debugReadbackBuffer.memory);
            }
        }

        VkRenderPassBeginInfo rpBegin = VkRenderPassBeginInfo.init;
        rpBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass = USE_LOAD_RENDERPASS ? offscreenRenderPassLoad : offscreenRenderPass;
        rpBegin.framebuffer = offscreenFramebuffer;
        rpBegin.renderArea.offset = VkOffset2D(0, 0);
        rpBegin.renderArea.extent = swapExtent;
        VkClearValue[4] clears;
        clears[0] = clearColor;        // albedo
        clears[1] = clearColor;        // emissive
        clears[2] = clearColor;        // bump
        clears[3].depthStencil = VkClearDepthStencilValue(1.0f, 0);
        rpBegin.clearValueCount = cast(uint)clears.length;
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
        paramsData.multColor = vec3(1, 0, 1); // magenta で目立たせる
        paramsData.screenColor = vec3(0, 0, 0);
        paramsData.emissionStrength = 1.0f;
        updateParamsUBO(paramsData);
        maskContentActive = false;
        // まず固定三角形を描いてパイプラインの健全性を確認し、さらに矩形を描く
        drawTestTriangle();
        // 明示的に矩形を描いて色が乗るか確認（NDC中央0.5四方、黄色）
        drawClipRectForced(vec4(-0.5f, -0.5f, 0.5f, 0.5f), vec3(1, 1, 0), 1.0f);
        // レンダーパス内で確実に色を書き込むデバッグ（全体を赤でクリア→すぐコピー）
        enum bool DEBUG_CLEAR_IN_PASS = false; // 強制塗りでレンダーパス経路を確認する
        if (DEBUG_CLEAR_IN_PASS) {
            VkClearAttachment[3] atts;
            VkClearRect rect;
            rect.rect.offset = VkOffset2D(0, 0);
            rect.rect.extent = swapExtent;
            rect.baseArrayLayer = 0;
            rect.layerCount = 1;
            foreach (i; 0 .. 3) {
                atts[i].aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                atts[i].colorAttachment = cast(uint)i;
                atts[i].clearValue.color.float32 = [1.0f, 0.0f, 0.0f, 1.0f]; // red
            }
            vkCmdClearAttachments(activeCommand, cast(uint)atts.length, atts.ptr, 1, &rect);

            // クリア直後に小領域をコピーして即時確認
            const int sampleW = 64;
            const int sampleH = 64;
            size_t sampleSize = sampleW * sampleH * 4;
            ensureReadbackBuffer(sampleSize);
            VkBufferImageCopy copy = VkBufferImageCopy.init;
            copy.bufferOffset = 0;
            copy.bufferRowLength = 0;
            copy.bufferImageHeight = 0;
            copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            copy.imageSubresource.mipLevel = 0;
            copy.imageSubresource.baseArrayLayer = 0;
            copy.imageSubresource.layerCount = 1;
            copy.imageOffset = VkOffset3D(0, 0, 0);
            copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
            recordTransition(activeCommand, mainAlbedo.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
            vkCmdCopyImageToBuffer(activeCommand, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                debugReadbackBuffer.buffer, 1, &copy);
            recordTransition(activeCommand, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
            // ここでマップして即ログ
            void* ptr;
            if (vkMapMemory(device, debugReadbackBuffer.memory, 0, sampleSize, 0, &ptr) == VK_SUCCESS) {
                auto mapped = (cast(ubyte*)ptr)[0 .. sampleSize];
                ulong sR=0,sG=0,sB=0,sA=0;
                foreach(i;0 .. sampleSize/4){
                    auto idx=i*4; sR+=mapped[idx]; sG+=mapped[idx+1]; sB+=mapped[idx+2]; sA+=mapped[idx+3];
                }
                double cnt=cast(double)(sampleSize/4);
                writefln("[VK passClear] avg=(%.3f,%.3f,%.3f,%.3f) first=%s", sR/cnt, sG/cnt, sB/cnt, sA/cnt, mapped[0..4]);
                vkUnmapMemory(device, debugReadbackBuffer.memory);
            }
        }
    }

    void endScene() {
        enforce(initialized, "Vulkan backend not initialized");
        if (skipRenderpassFrame) {
            debugSkipRenderpassBlit();
            skipRenderpassFrame = false;
            return;
        }
        auto cmd = frameCommands[currentFrame];
        if (debugSwapPassFrame) {
            VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            VkSubmitInfo submitInfo = VkSubmitInfo.init;
            submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submitInfo.waitSemaphoreCount = 1;
            submitInfo.pWaitSemaphores = &imageAvailable;
            submitInfo.pWaitDstStageMask = &waitStage;
            submitInfo.commandBufferCount = 1;
            submitInfo.pCommandBuffers = &cmd;
            submitInfo.signalSemaphoreCount = 1;
            submitInfo.pSignalSemaphores = &renderFinished;

            auto subRes = vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlightFences[currentFrame]);
            enforce(subRes == VK_SUCCESS, "Failed to submit debug swap command buffer");

            VkPresentInfoKHR presentInfo = VkPresentInfoKHR.init;
            presentInfo.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
            presentInfo.waitSemaphoreCount = 1;
            presentInfo.pWaitSemaphores = &renderFinished;
            presentInfo.swapchainCount = 1;
            presentInfo.pSwapchains = &swapchain;
            presentInfo.pImageIndices = &currentImageIndex;
            auto presentRes = vkQueuePresentKHR(presentQueue, &presentInfo);
            if (presentRes == VK_ERROR_OUT_OF_DATE_KHR || presentRes == VK_SUBOPTIMAL_KHR) {
                recreateSwapchain();
                swapchainValid = false;
            }
            debugSwapPassFrame = false;
            return;
        }
        // フレームunion領域を白塗りして blit 範囲を確認
        enum bool DEBUG_FILL_FRAME_UNION = true;
        if (DEBUG_FILL_FRAME_UNION && frameBoundsUnionClipValid) {
            // 有効な矩形のみ描画する
            if (frameBoundsUnionClip.x.isFinite && frameBoundsUnionClip.y.isFinite &&
                frameBoundsUnionClip.z.isFinite && frameBoundsUnionClip.w.isFinite &&
                frameBoundsUnionClip.z > frameBoundsUnionClip.x &&
                frameBoundsUnionClip.w > frameBoundsUnionClip.y) {
                drawClipRectForced(frameBoundsUnionClip, vec3(1, 1, 1), 1.0f);
            }
        }
        // デバッグ: パス末尾にもテスト三角をもう一度描いて、クリア後もパイプラインが動いているか確認
        drawTestTriangle();
        vkCmdEndRenderPass(cmd);
        // レンダーパス直後にオフスクリーン中央を読み出し、パス内書き込みを直接確認
        // レンダーパス直後のreadbackのみ残し、その他のコピーは抑制
        enum bool DEBUG_READBACK_AFTER_PASS = true;
        enum bool DEBUG_COMPARE_AFTER_PASS = false; // 2枚目に強制クリア結果を書き込んで比較
        const int sampleW = 64;
        const int sampleH = 64;
        size_t sampleSizeMain = sampleW * sampleH * 4;
        if (DEBUG_READBACK_AFTER_PASS) {
            size_t slots = DEBUG_COMPARE_AFTER_PASS ? 3 : 2; // main, (main cleared), swap
            ensureReadbackBuffer(sampleSizeMain * slots);
            VkBufferImageCopy copy = VkBufferImageCopy.init;
            copy.bufferOffset = 0;
            copy.bufferRowLength = 0;
            copy.bufferImageHeight = 0;
            copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            copy.imageSubresource.mipLevel = 0;
            copy.imageSubresource.baseArrayLayer = 0;
            copy.imageSubresource.layerCount = 1;
            int sx = cast(int)mainAlbedo.extent.width / 2 - sampleW / 2;
            int sy = cast(int)mainAlbedo.extent.height / 2 - sampleH / 2;
            if (sx < 0) sx = 0;
            if (sy < 0) sy = 0;
            copy.imageOffset = VkOffset3D(sx, sy, 0);
            copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
            vkCmdCopyImageToBuffer(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                debugReadbackBuffer.buffer, 1, &copy);
            if (DEBUG_COMPARE_AFTER_PASS) {
                // 強制緑クリア後の値を第2スロットに保存
                VkClearColorValue dbgColor;
                dbgColor.float32 = [0.0f, 1.0f, 0.0f, 1.0f];
                VkImageSubresourceRange rng = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
                vkCmdClearColorImage(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, &dbgColor, 1, &rng);
                VkBufferImageCopy copy2 = copy;
                copy2.bufferOffset = sampleSizeMain;
                vkCmdCopyImageToBuffer(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    debugReadbackBuffer.buffer, 1, &copy2);
            }
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
        }
        // パス外でも強制書き込みを入れて、カラーバッファ経路を確認
        enum bool DEBUG_FORCE_CLEAR_AFTER_PASS = false;
        if (DEBUG_FORCE_CLEAR_AFTER_PASS) {
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
            VkClearColorValue dbgColor;
            dbgColor.float32 = [0.0f, 1.0f, 0.0f, 1.0f]; // green
            VkImageSubresourceRange rng = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
            vkCmdClearColorImage(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &dbgColor, 1, &rng);
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
        } else {
            writefln("[VK layout] mainAlbedo COLOR_ATTACHMENT_OPTIMAL -> TRANSFER_SRC_OPTIMAL for readback");
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);
        }
        if (swapchainValid) {
            writefln("[VK layout] swap PRESENT -> TRANSFER_DST for blit");
            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);

            // デバッグ: 転送経路が生きているか強制色で確認
        enum bool DEBUG_FORCE_CLEAR_BEFORE_BLIT = false;
            if (DEBUG_FORCE_CLEAR_BEFORE_BLIT) {
                VkClearColorValue dbgColor;
                dbgColor.float32 = [1.0f, 0.0f, 0.0f, 1.0f]; // 赤
                VkImageSubresourceRange rng = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
                vkCmdClearColorImage(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, &dbgColor, 1, &rng);
                VkImageSubresourceRange swapRng = VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
                vkCmdClearColorImage(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &dbgColor, 1, &swapRng);
            }

            // デバッグ: オフスクリーンとスワップの両方を読み出して経路を確認
            enum bool DEBUG_READBACK = true;
            VkBufferImageCopy copy = VkBufferImageCopy.init;
            size_t baseOffset = DEBUG_COMPARE_AFTER_PASS ? sampleSizeMain * 2 : sampleSizeMain; // 先頭は endScene前半で使用済み
            if (DEBUG_READBACK) {
                ensureReadbackBuffer(sampleSizeMain * 3); // mainAlbedo(2枚) + swap
                // mainAlbedo中央付近 (前半スロットに上書き)
                copy.bufferOffset = 0;
                copy.bufferRowLength = 0;
                copy.bufferImageHeight = 0;
                copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                copy.imageSubresource.mipLevel = 0;
                copy.imageSubresource.baseArrayLayer = 0;
                copy.imageSubresource.layerCount = 1;
                int sx = cast(int)mainAlbedo.extent.width / 2 - sampleW / 2;
                int sy = cast(int)mainAlbedo.extent.height / 2 - sampleH / 2;
                if (sx < 0) sx = 0;
                if (sy < 0) sy = 0;
                copy.imageOffset = VkOffset3D(sx, sy, 0);
                copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
                vkCmdCopyImageToBuffer(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    debugReadbackBuffer.buffer, 1, &copy);
            }

            VkImageBlit blit = VkImageBlit.init;
            auto srcExtent = mainAlbedo.extent;
            if (srcExtent.width == 0 || srcExtent.height == 0) {
                srcExtent = swapExtent;
            }
            blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.srcSubresource.mipLevel = 0;
            blit.srcSubresource.baseArrayLayer = 0;
            blit.srcSubresource.layerCount = 1;
            blit.srcOffsets[0] = VkOffset3D(0, 0, 0);
            blit.srcOffsets[1] = VkOffset3D(cast(int)srcExtent.width, cast(int)srcExtent.height, 1);
            blit.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.dstSubresource.mipLevel = 0;
            blit.dstSubresource.baseArrayLayer = 0;
            blit.dstSubresource.layerCount = 1;
            blit.dstOffsets[0] = VkOffset3D(0, 0, 0);
            blit.dstOffsets[1] = VkOffset3D(cast(int)swapExtent.width, cast(int)swapExtent.height, 1);

            vkCmdBlitImage(cmd,
                mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1, &blit, VK_FILTER_NEAREST);

            if (DEBUG_READBACK) {
                // スワップイメージをサンプルして色が来ているか確認（blit後）
                VkBufferImageCopy copySwap = copy;
                copySwap.bufferOffset = baseOffset;
                // 一時的に読み取りレイアウトへ遷移
                recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
                vkCmdCopyImageToBuffer(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    debugReadbackBuffer.buffer, 1, &copySwap);
                // すぐ戻す
                recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
            }

            writefln("[VK layout] swap TRANSFER_DST -> PRESENT, mainAlbedo back to COLOR_ATTACHMENT");
            recordTransition(cmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_ASPECT_COLOR_BIT);
            recordTransition(cmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
        }
        auto endRes = vkEndCommandBuffer(cmd);
        if (endRes != VK_SUCCESS) {
            import std.stdio : writefln;
            writefln("[VK warn] vkEndCommandBuffer failed res=%s", endRes);
            activeCommand = null;
            return;
        }

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submitInfo = VkSubmitInfo.init;
        submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submitInfo.waitSemaphoreCount = 1;
        submitInfo.pWaitSemaphores = &imageAvailable;
        submitInfo.pWaitDstStageMask = &waitStage;
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &cmd;
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &renderFinished;

        auto subRes = vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlightFences[currentFrame]);
        if (subRes != VK_SUCCESS) {
            import std.stdio : writefln;
            writefln("[VK warn] vkQueueSubmit failed res=%s", subRes);
            activeCommand = null;
            return;
        }

        if (debugSwapPassFrame && debugReadbackBuffer.buffer !is null) {
            vkQueueWaitIdle(graphicsQueue);
            const uint sampleWDbg = 64;
            const uint sampleHDbg = 64;
            size_t sampleSize = sampleWDbg * sampleHDbg * 4;
            void* ptr;
            if (vkMapMemory(device, debugReadbackBuffer.memory, 0, sampleSize, 0, &ptr) == VK_SUCCESS) {
                auto mapped = (cast(ubyte*)ptr)[0 .. sampleSize];
                ulong sR=0,sG=0,sB=0,sA=0;
                foreach (i; 0 .. sampleSize/4) {
                    auto idx = i*4;
                    sR+=mapped[idx+0];
                    sG+=mapped[idx+1];
                    sB+=mapped[idx+2];
                    sA+=mapped[idx+3];
                }
                double cnt = cast(double)(sampleSize/4);
                writefln("[VK debugSwap] avg=(%.3f,%.3f,%.3f,%.3f) first=%s",
                    sR/cnt, sG/cnt, sB/cnt, sA/cnt, mapped[0..4]);
                writefln("[VK debugSwap] sample (0,0) RGBA=%s", mapped[0 .. 4]);
                vkUnmapMemory(device, debugReadbackBuffer.memory);
            }
        }

        VkPresentInfoKHR presentInfo = VkPresentInfoKHR.init;
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
            if (presentRes != VK_SUCCESS) {
                import std.stdio : writefln;
                writefln("[VK warn] vkQueuePresentKHR failed res=%s", presentRes);
                swapchainValid = false;
            }
        }
        // デバッグ読み出し: CPU に戻して平均色を表示（オフスクリーン＋スワップの2枚）
        enum bool DEBUG_READBACK = true;
        if (DEBUG_READBACK && debugReadbackBuffer.buffer !is null) {
            vkQueueWaitIdle(graphicsQueue);
            // コマンドバッファ内でコピーした mainAlbedo と swap の内容をそのまま読む
            if (debugReadbackBuffer.size > 0) {
                void* ptr;
                if (vkMapMemory(device, debugReadbackBuffer.memory, 0, debugReadbackBuffer.size, 0, &ptr) == VK_SUCCESS) {
                    auto mapped = (cast(ubyte*)ptr)[0 .. debugReadbackBuffer.size];
                    auto dumpAvg = (string label, ubyte[] slice) {
                        ulong sumR = 0, sumG = 0, sumB = 0, sumA = 0;
                        size_t pixels = slice.length / 4;
                        foreach (i; 0 .. pixels) {
                            sumR += slice[i * 4 + 0];
                            sumG += slice[i * 4 + 1];
                            sumB += slice[i * 4 + 2];
                            sumA += slice[i * 4 + 3];
                        }
                        float inv = pixels > 0 ? 1.0f / pixels : 0;
                        writefln("[VK readback %s] %spx avg=(%f,%f,%f,%f) first=%s",
                            label, pixels, sumR * inv, sumG * inv, sumB * inv, sumA * inv,
                            pixels > 0 ? slice[0 .. 4] : []);
                    };
                    auto sliceSize = sampleSizeMain;
                    auto totalSlices = sliceSize > 0 ? mapped.length / sliceSize : 0;
                    if (sliceSize == 0 || totalSlices == 0) {
                        dumpAvg("buffer", mapped);
                    } else {
                        foreach (i; 0 .. totalSlices) {
                            auto start = i * sliceSize;
                            auto end = start + sliceSize;
                            if (end > mapped.length) break;
                            string label;
                            if (i == 0) label = "offscreen_before";
                            else if (i == 1 && DEBUG_COMPARE_AFTER_PASS) label = "offscreen_after_clear";
                            else label = i == totalSlices - 1 ? "swap" : "slice";
                            dumpAvg(label, mapped[start .. end]);
                        }
                    }
                    vkUnmapMemory(device, debugReadbackBuffer.memory);
                }
            }
        }

        if (frameBoundsUnionValid) {
            writefln("[VK bounds] frame union screen(px)=%s", frameBoundsUnion);
        }
        activeCommand = null;
        currentFrame = (currentFrame + 1) % maxFramesInFlight;
    }
    void postProcessScene() { /* TODO: implement post-processing path */ }

    /// レンダーパスをスキップしたフレーム用: 単発コマンドで mainAlbedo を塗り、ブリット経路を検証
    void debugSkipRenderpassBlit() {
        const int sampleW = 64;
        const int sampleH = 64;
        size_t sampleSize = sampleW * sampleH * 4;
        // swap 直接のクリア確認 + mainAlbedo 経路で計 2 サンプル必要
        ensureReadbackBuffer(sampleSize * 2);

        if (!swapchainValid) {
            writefln("[VK dbg] skipRenderpass: swapchain invalid, abort");
            return;
        }

        auto sCmd = beginSingleTimeCommands();
        const int rectSize = 512;
        ensureDebugRectBuffer(rectSize, rectSize, 0, 255, 0, 255); // 塗りつぶし矩形
        // まず swap イメージ単体で TRANSFER 経路と readback が生きているか確認
        recordTransition(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
        VkClearColorValue swapClr; swapClr.float32 = [0.0f, 0.0f, 0.0f, 1.0f]; // black for contrast
        VkImageSubresourceRange swapRange = VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1);
        vkCmdClearColorImage(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &swapClr, 1, &swapRange);
        recordTransition(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
        VkBufferImageCopy swapCopy = VkBufferImageCopy.init;
        swapCopy.bufferOffset = sampleSize; // 後半に swap を配置
        swapCopy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        swapCopy.imageSubresource.mipLevel = 0;
        swapCopy.imageSubresource.baseArrayLayer = 0;
        swapCopy.imageSubresource.layerCount = 1;
        // サンプル位置も中央寄りに揃える
        swapCopy.imageOffset = VkOffset3D(cast(int)swapExtent.width / 2 - sampleW / 2,
            cast(int)swapExtent.height / 2 - sampleH / 2, 0);
        swapCopy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
        vkCmdCopyImageToBuffer(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            debugReadbackBuffer.buffer, 1, &swapCopy);
        recordTransition(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_ASPECT_COLOR_BIT);
        // mainAlbedo に赤を書き込む
        recordTransition(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mainAlbedo.aspect);
        VkClearColorValue clr; clr.float32 = [1.0f, 0.0f, 1.0f, 1.0f]; // magenta base
        VkImageSubresourceRange rng = VkImageSubresourceRange(mainAlbedo.aspect, 0, 1, 0, 1);
        vkCmdClearColorImage(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clr, 1, &rng);
        // 中央付近に rectSize x rectSize の緑矩形を書き込む
        VkBufferImageCopy rectCopy = VkBufferImageCopy.init;
        rectCopy.bufferOffset = 0;
        rectCopy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        rectCopy.imageSubresource.mipLevel = 0;
        rectCopy.imageSubresource.baseArrayLayer = 0;
        rectCopy.imageSubresource.layerCount = 1;
        int rx = cast(int)mainAlbedo.extent.width / 2 - rectSize / 2;
        int ry = cast(int)mainAlbedo.extent.height / 2 - rectSize / 2;
        if (rx < 0) rx = 0;
        if (ry < 0) ry = 0;
        rectCopy.imageOffset = VkOffset3D(rx, ry, 0);
        rectCopy.imageExtent = VkExtent3D(rectSize, rectSize, 1);
        vkCmdCopyBufferToImage(sCmd, debugRectBuffer.buffer, mainAlbedo.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &rectCopy);
        recordTransition(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, mainAlbedo.aspect);

        // mainAlbedo → readback (前半)
        VkBufferImageCopy copy = VkBufferImageCopy.init;
        copy.bufferOffset = 0; // 前半に mainAlbedo
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.mipLevel = 0;
        copy.imageSubresource.baseArrayLayer = 0;
        copy.imageSubresource.layerCount = 1;
        // 矩形中央を読む
        copy.imageOffset = VkOffset3D(rx, ry, 0);
        copy.imageExtent = VkExtent3D(sampleW, sampleH, 1);
        vkCmdCopyImageToBuffer(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            debugReadbackBuffer.buffer, 1, &copy);

        // mainAlbedo → swap blit
        recordTransition(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
        VkImageBlit blit = VkImageBlit.init;
        blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        blit.srcSubresource.mipLevel = 0;
        blit.srcSubresource.baseArrayLayer = 0;
        blit.srcSubresource.layerCount = 1;
        blit.srcOffsets[0] = VkOffset3D(0, 0, 0);
        blit.srcOffsets[1] = VkOffset3D(cast(int)mainAlbedo.extent.width, cast(int)mainAlbedo.extent.height, 1);
        blit.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        blit.dstSubresource.mipLevel = 0;
        blit.dstSubresource.baseArrayLayer = 0;
        blit.dstSubresource.layerCount = 1;
        blit.dstOffsets[0] = VkOffset3D(0, 0, 0);
        blit.dstOffsets[1] = VkOffset3D(cast(int)swapExtent.width, cast(int)swapExtent.height, 1);
        vkCmdBlitImage(sCmd,
            mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1, &blit, VK_FILTER_NEAREST);

        // swap → readback (後半)
        VkBufferImageCopy copySwap = copy;
        copySwap.bufferOffset = sampleSize;
        recordTransition(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
        vkCmdCopyImageToBuffer(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            debugReadbackBuffer.buffer, 1, &copySwap);

        // 戻す
        recordTransition(sCmd, swapImages[currentImageIndex], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_ASPECT_COLOR_BIT);
        recordTransition(sCmd, mainAlbedo.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, mainAlbedo.aspect);
        endSingleTimeCommands(sCmd);

        // 読み出しログ
        void* ptr;
        if (vkMapMemory(device, debugReadbackBuffer.memory, 0, debugReadbackBuffer.size, 0, &ptr) == VK_SUCCESS) {
            auto mapped = (cast(ubyte*)ptr)[0 .. debugReadbackBuffer.size];
            auto dump = (string label, ubyte[] slice) {
                ulong r=0,g=0,b=0,a=0; size_t px = slice.length/4;
                foreach(i;0 .. px){ auto idx=i*4; r+=slice[idx]; g+=slice[idx+1]; b+=slice[idx+2]; a+=slice[idx+3]; }
                float inv = px? 1.0f/px : 0;
                writefln("[VK skipPass %s] %spx avg=(%f,%f,%f,%f) first=%s",
                    label, px, r*inv, g*inv, b*inv, a*inv, px? slice[0..4]:[]);
            };
            size_t half = debugReadbackBuffer.size/2;
            dump("offscreen", mapped[0 .. half]);
            dump("swap", mapped[half .. debugReadbackBuffer.size]);
            vkUnmapMemory(device, debugReadbackBuffer.memory);
        }
    }

    void initializeDrawableResources() {
        destroyBuffer(globalsUbo);
        destroyBuffer(paramsUbo);
        destroyBuffer(sharedVertexBuffer);
        destroyBuffer(sharedUvBuffer);
        destroyBuffer(sharedDeformBuffer);
        destroyBuffer(compositePosBuffer);
        destroyBuffer(compositeUvBuffer);
        destroyBuffer(quadPosXBuffer);
        destroyBuffer(quadPosYBuffer);
        destroyBuffer(quadUvXBuffer);
        destroyBuffer(quadUvYBuffer);
        destroyBuffer(quadDeformXBuffer);
        destroyBuffer(quadDeformYBuffer);
        destroyBuffer(debugRectBuffer);
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
    void uploadSharedVertexBuffer(Vec2Array vertices) { uploadSharedVecBuffer(sharedVertexBuffer, vertices); }
    void uploadSharedUvBuffer(Vec2Array uvs) { uploadSharedVecBuffer(sharedUvBuffer, uvs); }
    void uploadSharedDeformBuffer(Vec2Array deform) { uploadSharedVecBuffer(sharedDeformBuffer, deform); }
    void drawDrawableElements(RenderResourceHandle ibo, size_t indexCount) {
        if (activeCommand is null || indexCount == 0) return;
        auto entry = ibo in indexBuffers;
        if (entry is null || (*entry).buffer is null) return;
        vkCmdBindIndexBuffer(activeCommand, (*entry).buffer, 0, VK_INDEX_TYPE_UINT16);
        vkCmdDrawIndexed(activeCommand, cast(uint)indexCount, 1, 0, 0, 0);
    }

    void uploadSharedVecBuffer(ref Buffer target, Vec2Array data) {
        destroyBuffer(target);
        auto raw = data.rawStorage();
        if (raw.length == 0) return;
        size_t sz = raw.length * float.sizeof;
        Buffer staging = createBuffer(sz, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        scope (exit) destroyBuffer(staging);
        void* mapped;
        vkMapMemory(device, staging.memory, 0, staging.size, 0, &mapped);
        auto dst = cast(float*)mapped;
        dst[0 .. raw.length] = raw[];
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
            dynamicDummyDepth = createImage(extent, selectDepthFormat(),
                VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, depthAspect(selectDepthFormat()), 1);
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

        VkFramebufferCreateInfo fb = VkFramebufferCreateInfo.init;
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
        // Debug: log first few part packets to catch NaN/zero data issues.
        // Verbose dbg logsは抑制
        // 追加: 実頂点とMVP適用後の簡易boundsをログ（常に）
        enum size_t BOUNDS_LIMIT = size_t.max;
        enum bool DEBUG_ATTRS = true; // 頂点/UV/変形の入力確認用（少量に制限）
        enum size_t ATTRS_LIMIT = 8;
        static size_t boundsLogged = 0;
        static size_t attrsLogged = 0;
        vec4 clipBounds = vec4(float.nan, float.nan, float.nan, float.nan);
        if (boundsLogged < BOUNDS_LIMIT || (DEBUG_ATTRS && attrsLogged < ATTRS_LIMIT)) {
            auto vdata = sharedVertexBufferData();
            auto laneX = vdata.lane(0);
            auto laneY = vdata.lane(1);
            auto uvdata = sharedUvBufferData();
            auto laneUX = uvdata.lane(0);
            auto laneUY = uvdata.lane(1);
            auto ddef = sharedDeformBufferData();
            auto laneDX = ddef.lane(0);
            auto laneDY = ddef.lane(1);
            size_t start = packet.vertexOffset;
            size_t count = packet.vertexCount;
            if (start + count > vdata.length) {
                count = vdata.length > start ? vdata.length - start : 0;
            }
            vec4 screenBounds = vec4(float.nan, float.nan, float.nan, float.nan);
            auto mvp = inGetCamera().matrix * packet.puppetMatrix * packet.modelMatrix;
            auto vpW = cast(float)swapExtent.width;
            auto vpH = cast(float)swapExtent.height;
            foreach (i; 0 .. count) {
                auto idx = start + i;
                auto x = laneX[idx];
                auto y = laneY[idx];
                if (!isFinite(x) || !isFinite(y)) continue;
                // 実際のシェーダと同じく origin を引いて MVP 適用
                vec4 local = vec4(x - packet.origin.x, y - packet.origin.y, 0, 1);
                auto clip = mvp * local;
                float w = clip.w == 0 ? 1 : clip.w;
                float cx = clip.x / w;
                float cy = clip.y / w;
                if (!isFinite(cx) || !isFinite(cy)) continue;
                if (!isFinite(clipBounds.x)) {
                    clipBounds = vec4(cx, cy, cx, cy);
                } else {
                    if (cx < clipBounds.x) clipBounds.x = cx;
                    if (cy < clipBounds.y) clipBounds.y = cy;
                    if (cx > clipBounds.z) clipBounds.z = cx;
                    if (cy > clipBounds.w) clipBounds.w = cy;
                }
                // screen-space bounds (NDC -> viewport pixels)
                float sx = (cx * 0.5f + 0.5f) * vpW;
                float sy = (cy * 0.5f + 0.5f) * vpH;
            if (!isFinite(sx) || !isFinite(sy)) continue;
            if (!isFinite(screenBounds.x)) {
                screenBounds = vec4(sx, sy, sx, sy);
            } else {
                if (sx < screenBounds.x) screenBounds.x = sx;
                    if (sy < screenBounds.y) screenBounds.y = sy;
                if (sx > screenBounds.z) screenBounds.z = sx;
                if (sy > screenBounds.w) screenBounds.w = sy;
                }
            }
            writefln("[VK bounds] part \"%s\" screen(px)=%s count=%s",
                packet.name, screenBounds, count);
            if (DEBUG_ATTRS && attrsLogged < ATTRS_LIMIT) {
                size_t dumpN = count < 4 ? count : 4;
                writefln("[VK verts] part \"%s\" first %s verts (raw):", packet.name, dumpN);
                foreach (i; 0 .. dumpN) {
                    auto idx = start + i;
                    auto vx = laneX[idx];
                    auto vy = laneY[idx];
                    auto ux = laneUX[idx];
                    auto uy = laneUY[idx];
                    auto dx = laneDX[idx];
                    auto dy = laneDY[idx];
                    writefln("  idx=%s pos=(%f,%f) deform=(%f,%f) uv=(%f,%f)", idx, vx, vy, dx, dy, ux, uy);
                }
                writefln("[VK verts] shader input uses vec2(vert - origin + deform); origin=%s", packet.origin);
                ++attrsLogged;
            }
            // フレーム内unionを更新
            if (screenBounds.x.isFinite && screenBounds.y.isFinite && screenBounds.z.isFinite && screenBounds.w.isFinite) {
                if (!frameBoundsUnionValid) {
                    frameBoundsUnion = screenBounds;
                    frameBoundsUnionValid = true;
                } else {
                    if (screenBounds.x < frameBoundsUnion.x) frameBoundsUnion.x = screenBounds.x;
                    if (screenBounds.y < frameBoundsUnion.y) frameBoundsUnion.y = screenBounds.y;
                    if (screenBounds.z > frameBoundsUnion.z) frameBoundsUnion.z = screenBounds.z;
                    if (screenBounds.w > frameBoundsUnion.w) frameBoundsUnion.w = screenBounds.w;
                }
            }
            if (clipBounds.x.isFinite && clipBounds.y.isFinite && clipBounds.z.isFinite && clipBounds.w.isFinite) {
                if (!frameBoundsUnionClipValid) {
                    frameBoundsUnionClip = clipBounds;
                    frameBoundsUnionClipValid = true;
                } else {
                    if (clipBounds.x < frameBoundsUnionClip.x) frameBoundsUnionClip.x = clipBounds.x;
                    if (clipBounds.y < frameBoundsUnionClip.y) frameBoundsUnionClip.y = clipBounds.y;
                    if (clipBounds.z > frameBoundsUnionClip.z) frameBoundsUnionClip.z = clipBounds.z;
                    if (clipBounds.w > frameBoundsUnionClip.w) frameBoundsUnionClip.w = clipBounds.w;
                }
            }
            ++boundsLogged;
        }
        enum bool DEBUG_DRAW_BOUNDS = true;
        // 画面上にバウンズ矩形を描画（デバッグ）
        if (DEBUG_DRAW_BOUNDS &&
            clipBounds.x.isFinite && clipBounds.y.isFinite && clipBounds.z.isFinite && clipBounds.w.isFinite) {
            drawClipRect(clipBounds, vec3(0, 1, 0), 0.15f);
        }
        auto cam = inGetCamera();
        globalsData.mvp = cam.matrix * packet.puppetMatrix * packet.modelMatrix;
        globalsData.offset = packet.origin;
        updateGlobalsUBO(globalsData);

        // デバッグ: シェーダ入力の色/不透明度を強制して描画確認
        enum bool DEBUG_FORCE_COLOR = true;
        if (DEBUG_FORCE_COLOR) {
            paramsData.opacity = 1.0f;
            paramsData.multColor = vec3(1, 1, 1);
            paramsData.screenColor = vec3(0, 0, 0);
            paramsData.emissionStrength = 0.0f;
        } else {
            paramsData.opacity = packet.opacity;
            paramsData.multColor = packet.clampedTint;
            paramsData.screenColor = packet.clampedScreen;
            paramsData.emissionStrength = packet.emissionStrength;
        }
        updateParamsUBO(paramsData);

        enum bool DEBUG_FORCE_WHITE = true; // パーツ形状確認のため白テクスチャを強制
        if (DEBUG_FORCE_WHITE) {
            bindTextureHandle(debugWhiteTex, 1);
            bindTextureHandle(debugWhiteTex, 2);
            bindTextureHandle(debugWhiteTex, 3);
        } else {
            foreach (i, tex; packet.textures) {
                if (tex !is null) {
                    bindTextureHandle(tex.backendHandle(), cast(uint)(i + 1));
                }
            }
        }

        // Bind SoA vertex buffers: X/Y, UV X/Y, Deform X/Y
        if (sharedVertexBuffer.buffer is null || sharedUvBuffer.buffer is null || sharedDeformBuffer.buffer is null) return;
        auto vStride = packet.vertexAtlasStride * float.sizeof;
        auto uvStride = packet.uvAtlasStride * float.sizeof;
        auto dStride = packet.deformAtlasStride * float.sizeof;
        VkBuffer[6] bufs;
        VkDeviceSize[6] offs;
        uint bindCount = 0;
        // position X / Y
        bufs[bindCount] = sharedVertexBuffer.buffer; offs[bindCount] = packet.vertexOffset * float.sizeof; ++bindCount;
        bufs[bindCount] = sharedVertexBuffer.buffer; offs[bindCount] = (packet.vertexAtlasStride + packet.vertexOffset) * float.sizeof; ++bindCount;
        // uv X / Y
        bufs[bindCount] = sharedUvBuffer.buffer; offs[bindCount] = packet.uvOffset * float.sizeof; ++bindCount;
        bufs[bindCount] = sharedUvBuffer.buffer; offs[bindCount] = (packet.uvAtlasStride + packet.uvOffset) * float.sizeof; ++bindCount;
        // deform X / Y
        bufs[bindCount] = sharedDeformBuffer.buffer; offs[bindCount] = packet.deformOffset * float.sizeof; ++bindCount;
        bufs[bindCount] = sharedDeformBuffer.buffer; offs[bindCount] = (packet.deformAtlasStride + packet.deformOffset) * float.sizeof; ++bindCount;
        vkCmdBindVertexBuffers(activeCommand, 0, bindCount, bufs.ptr, offs.ptr);

        useShader(null);
        drawDrawableElements(packet.indexBuffer, packet.indexCount);
    }
    void beginDynamicComposite(DynamicCompositePass pass) {
        if (pass is null || pass.surface is null) return;
        auto state = createDynamicCompositeFramebuffer(pass.surface);
        if (state is null) return;
        // Allocate a transient command buffer for this composite pass.
        VkCommandBufferAllocateInfo alloc = VkCommandBufferAllocateInfo.init;
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.commandPool = commandPool;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = 1;
        VkCommandBuffer cmd;
        enforce(vkAllocateCommandBuffers(device, &alloc, &cmd) == VK_SUCCESS,
            "Failed to allocate dynamic composite command buffer");

        VkCommandBufferBeginInfo beginInfo = VkCommandBufferBeginInfo.init;
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

        VkRenderPassBeginInfo rpBegin = VkRenderPassBeginInfo.init;
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

        auto endRes = vkEndCommandBuffer(cmd);
        if (endRes != VK_SUCCESS) {
            import std.stdio : writefln;
            writefln("[VK warn] endDynamicComposite vkEndCommandBuffer=%s", endRes);
            vkFreeCommandBuffers(device, commandPool, 1, &cmd);
            activeCommand = commandBeforeDynamic;
            commandBeforeDynamic = null;
            return;
        }

        VkSubmitInfo submit = VkSubmitInfo.init;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        auto subRes = vkQueueSubmit(graphicsQueue, 1, &submit, VK_NULL_HANDLE);
        if (subRes != VK_SUCCESS) {
            import std.stdio : writefln;
            writefln("[VK warn] endDynamicComposite submit failed res=%s", subRes);
            vkFreeCommandBuffers(device, commandPool, 1, &cmd);
            activeCommand = commandBeforeDynamic;
            commandBeforeDynamic = null;
            return;
        }
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
        VkClearAttachment clear = VkClearAttachment.init;
        clear.aspectMask = VK_IMAGE_ASPECT_STENCIL_BIT;
        clear.colorAttachment = 0;
        clear.clearValue.depthStencil = VkClearDepthStencilValue(1.0f, useStencil ? 0 : 1);
        VkClearRect clearRect = VkClearRect.init;
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

        // Bind SoA vertex/deform buffers (X/Y each)
        if (sharedVertexBuffer.buffer is null || sharedDeformBuffer.buffer is null) return;
        size_t vertOff = packet.kind == MaskDrawableKind.Part ? packet.partPacket.vertexOffset
                                                              : packet.maskPacket.vertexOffset;
        size_t vertStride = packet.kind == MaskDrawableKind.Part ? packet.partPacket.vertexAtlasStride
                                                                 : packet.maskPacket.vertexAtlasStride;
        size_t deformOff = packet.kind == MaskDrawableKind.Part ? packet.partPacket.deformOffset
                                                                : packet.maskPacket.deformOffset;
        size_t deformStride = packet.kind == MaskDrawableKind.Part ? packet.partPacket.deformAtlasStride
                                                                   : packet.maskPacket.deformAtlasStride;
        VkBuffer[4] vertexBuffers;
        VkDeviceSize[4] offsets;
        vertexBuffers[0] = sharedVertexBuffer.buffer;
        offsets[0] = vertOff * float.sizeof;
        vertexBuffers[1] = sharedVertexBuffer.buffer;
        offsets[1] = vertStride * float.sizeof + vertOff * float.sizeof;
        vertexBuffers[2] = sharedDeformBuffer.buffer;
        offsets[2] = deformOff * float.sizeof;
        vertexBuffers[3] = sharedDeformBuffer.buffer;
        offsets[3] = deformStride * float.sizeof + deformOff * float.sizeof;
        vkCmdBindVertexBuffers(activeCommand, 0, 4, vertexBuffers.ptr, offsets.ptr);
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
        // Static zero deform (two lanes, 6 verts)
        float[6] zeros = [0, 0, 0, 0, 0, 0];
        if (quadDeformXBuffer.buffer is null || quadDeformYBuffer.buffer is null) {
            uploadBufferData(quadDeformXBuffer, zeros[]);
            uploadBufferData(quadDeformYBuffer, zeros[]);
        }
        // positions/uv buffersも存在しない場合は確保
        if (quadPosXBuffer.buffer is null) uploadBufferData(quadPosXBuffer, zeros[]);
        if (quadPosYBuffer.buffer is null) uploadBufferData(quadPosYBuffer, zeros[]);
        if (quadUvXBuffer.buffer is null) uploadBufferData(quadUvXBuffer, zeros[]);
        if (quadUvYBuffer.buffer is null) uploadBufferData(quadUvYBuffer, zeros[]);
    }
    void drawClipRect(vec4 clipBounds, vec3 color = vec3(1, 1, 1), float opacity = 0.2f) {
        if (!debugDrawBounds) return;
        if (activeCommand is null) return;
        ensureQuadBuffers();
        // clipBounds: [minX, minY, maxX, maxY] in NDC
        float x0 = clipBounds.x;
        float y0 = clipBounds.y;
        float x1 = clipBounds.z;
        float y1 = clipBounds.w;
        float[6] posX = [x0, x1, x0, x1, x0, x1];
        float[6] posY = [y0, y0, y1, y1, y1, y0];
        float[6] uvX = [0, 1, 0, 1, 0, 1];
        float[6] uvY = [0, 0, 1, 1, 1, 0];
        uploadBufferData(quadPosXBuffer, posX[]);
        uploadBufferData(quadPosYBuffer, posY[]);
        uploadBufferData(quadUvXBuffer, uvX[]);
        uploadBufferData(quadUvYBuffer, uvY[]);
        // Deform buffers are zero-filled already.

        // Identity MVP, no offset; positions are already clip-space.
        globalsData.mvp = mat4.identity;
        globalsData.offset = vec2(0, 0);
        updateGlobalsUBO(globalsData);
        paramsData.opacity = opacity;
        paramsData.multColor = color;
        paramsData.screenColor = vec3(0, 0, 0);
        paramsData.emissionStrength = 1.0f;
        updateParamsUBO(paramsData);
        bindTextureHandle(debugWhiteTex, 1);
        bindTextureHandle(debugWhiteTex, 2);
        bindTextureHandle(debugWhiteTex, 3);
        auto pipeline = basicPipeline;
        if (pipeline is null) return;
        vkCmdBindPipeline(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (descriptorSet !is null) {
            vkCmdBindDescriptorSets(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptorSet, 0, null);
        }
        VkBuffer[6] vertexBuffers = [quadPosXBuffer.buffer, quadPosYBuffer.buffer, quadUvXBuffer.buffer, quadUvYBuffer.buffer, quadDeformXBuffer.buffer, quadDeformYBuffer.buffer];
        foreach (buf; vertexBuffers) {
            if (buf is null) return; // safety: skip if any buffer missing
        }
        VkDeviceSize[6] offsets = [0, 0, 0, 0, 0, 0];
        vkCmdBindVertexBuffers(activeCommand, 0, 6, vertexBuffers.ptr, offsets.ptr);
        vkCmdDraw(activeCommand, 6, 1, 0, 0);
    }
    void drawTestTriangle() {
        enum bool DEBUG_DRAW_TEST_TRI = true;
        if (!DEBUG_DRAW_TEST_TRI) return;
        if (activeCommand is null) return;
        ensureQuadBuffers();
        // 三角形をNDC中央付近に配置（-0.5..0.5）
        float[6] posX = [-0.5f, 0.5f, 0.0f, 0, 0, 0];
        float[6] posY = [-0.5f, -0.5f, 0.5f, 0, 0, 0];
        float[6] uvX = [0, 1, 0.5f, 0, 0, 0];
        float[6] uvY = [0, 0, 1, 0, 0, 0];
        float[6] zeros = [0, 0, 0, 0, 0, 0];
        uploadBufferData(quadPosXBuffer, posX[]);
        uploadBufferData(quadPosYBuffer, posY[]);
        uploadBufferData(quadUvXBuffer, uvX[]);
        uploadBufferData(quadUvYBuffer, uvY[]);
        uploadBufferData(quadDeformXBuffer, zeros[]);
        uploadBufferData(quadDeformYBuffer, zeros[]);

        globalsData.mvp = mat4.identity;
        globalsData.offset = vec2(0, 0);
        updateGlobalsUBO(globalsData);
        paramsData.opacity = 1.0f;
        paramsData.multColor = vec3(1, 1, 1);
        paramsData.screenColor = vec3(0, 0, 0);
        paramsData.emissionStrength = 1.0f;
        updateParamsUBO(paramsData);
        bindTextureHandle(debugWhiteTex, 1);
        bindTextureHandle(debugWhiteTex, 2);
        bindTextureHandle(debugWhiteTex, 3);

        auto pipeline = basicPipeline;
        if (pipeline is null) return;
        vkCmdBindPipeline(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (descriptorSet !is null) {
            vkCmdBindDescriptorSets(activeCommand, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptorSet, 0, null);
        }
        VkBuffer[6] vertexBuffers = [quadPosXBuffer.buffer, quadPosYBuffer.buffer, quadUvXBuffer.buffer, quadUvYBuffer.buffer, quadDeformXBuffer.buffer, quadDeformYBuffer.buffer];
        foreach (buf; vertexBuffers) if (buf is null) return;
        VkDeviceSize[6] offsets = [0, 0, 0, 0, 0, 0];
        vkCmdBindVertexBuffers(activeCommand, 0, 6, vertexBuffers.ptr, offsets.ptr);
        vkCmdDraw(activeCommand, 3, 1, 0, 0);
    }
    void drawClipRectForced(vec4 clipBounds, vec3 color = vec3(1, 1, 1), float opacity = 0.2f) {
        if (activeCommand is null) return;
        bool prev = debugDrawBounds;
        debugDrawBounds = true;
        // clamp to sane NDC to avoid invalid coordinates
        vec4 clamped = vec4(
            clamp(clipBounds.x, -1f, 1f),
            clamp(clipBounds.y, -1f, 1f),
            clamp(clipBounds.z, -1f, 1f),
            clamp(clipBounds.w, -1f, 1f));
        drawClipRect(clamped, color, opacity);
        debugDrawBounds = prev;
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
        // SoAに分解してアップロード
        float[6] posX; float[6] posY;
        foreach (i; 0 .. 6) {
            posX[i] = positions[i * 2 + 0];
            posY[i] = positions[i * 2 + 1];
        }
        float[6] uvX; float[6] uvY;
        foreach (i; 0 .. 6) {
            uvX[i] = uvData[i * 2 + 0];
            uvY[i] = uvData[i * 2 + 1];
        }
        uploadBufferData(quadPosXBuffer, posX[]);
        uploadBufferData(quadPosYBuffer, posY[]);
        uploadBufferData(quadUvXBuffer, uvX[]);
        uploadBufferData(quadUvYBuffer, uvY[]);

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
        VkBuffer[6] vertexBuffers = [quadPosXBuffer.buffer, quadPosYBuffer.buffer, quadUvXBuffer.buffer, quadUvYBuffer.buffer, quadDeformXBuffer.buffer, quadDeformYBuffer.buffer];
        VkDeviceSize[6] offsets = [0, 0, 0, 0, 0, 0];
        vkCmdBindVertexBuffers(activeCommand, 0, 6, vertexBuffers.ptr, offsets.ptr);
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
        // 通常のハンドルを使用（デバッグ強制はオフ）
        auto handle = cast(VkTextureHandle)texture;
        if (handle is null || descriptorSet is null) return;
        enforce(unit >= 1 && unit <= 3, "Texture unit out of range for basic shader");
        VkDescriptorImageInfo imageInfo = VkDescriptorImageInfo.init;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        imageInfo.imageView = handle.image.view;
        imageInfo.sampler = handle.sampler;

        VkWriteDescriptorSet write = VkWriteDescriptorSet.init;
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
            format = selectDepthFormat();
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

        VkBufferImageCopy region = VkBufferImageCopy.init;
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

            VkImageBlit blit = VkImageBlit.init;
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

        VkBufferImageCopy region = VkBufferImageCopy.init;
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
        VkApplicationInfo appInfo = VkApplicationInfo.init;
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName = "nijilive".toStringz();
        appInfo.pEngineName = "nijilive".toStringz();
        appInfo.apiVersion = VK_API_VERSION_1_0;

        VkInstanceCreateInfo createInfo = VkInstanceCreateInfo.init;
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.pApplicationInfo = &appInfo;
        const(char)*[] extPtrs;
        if (instanceExtensions.length) {
            extPtrs.length = instanceExtensions.length;
            foreach (i, ext; instanceExtensions) {
                extPtrs[i] = ext.toStringz();
            }
            createInfo.enabledExtensionCount = cast(uint)extPtrs.length;
            createInfo.ppEnabledExtensionNames = extPtrs.ptr;
        }
        if (instanceExtensions.canFind("VK_KHR_portability_enumeration")) {
            createInfo.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }

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

    VkFormat selectDepthFormat() {
        VkFormat[3] candidates = [
            VK_FORMAT_D24_UNORM_S8_UINT,
            VK_FORMAT_D32_SFLOAT_S8_UINT,
            VK_FORMAT_D32_SFLOAT,
        ];
        foreach (fmt; candidates) {
            VkFormatProperties props = VkFormatProperties.init;
            vkGetPhysicalDeviceFormatProperties(physicalDevice, fmt, &props);
            if ((props.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) != 0) {
                return fmt;
            }
        }
        enforce(false, "No suitable depth format found");
        return VK_FORMAT_D32_SFLOAT;
    }

    VkImageAspectFlags depthAspect(VkFormat fmt) {
        switch (fmt) {
            case VK_FORMAT_D24_UNORM_S8_UINT:
            case VK_FORMAT_D32_SFLOAT_S8_UINT:
                return VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT;
            default:
                return VK_IMAGE_ASPECT_DEPTH_BIT;
        }
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

        VkDeviceCreateInfo createInfo = VkDeviceCreateInfo.init;
        createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        createInfo.queueCreateInfoCount = queueInfoCount;
        createInfo.pQueueCreateInfos = queueInfos.ptr;
        // Filter and enable only supported device extensions.
        string[] enabledDevExts;
        if (deviceExtensions.length) {
            uint extCount = 0;
            enforce(vkEnumerateDeviceExtensionProperties(physicalDevice, null, &extCount, null) == VK_SUCCESS,
                "Failed to enumerate device extensions");
            VkExtensionProperties[] props;
            props.length = extCount;
            enforce(vkEnumerateDeviceExtensionProperties(physicalDevice, null, &extCount, props.ptr) == VK_SUCCESS,
                "Failed to enumerate device extensions");
            foreach (ext; deviceExtensions) {
                bool supported = false;
                foreach (p; props) {
                    auto name = fromStringz(p.extensionName.ptr);
                    if (name == ext) { supported = true; break; }
                }
                enforce(supported, "Required device extension not supported: "~ext);
                enabledDevExts ~= ext;
            }
            const(char)*[] devExtPtrs;
            devExtPtrs.length = enabledDevExts.length;
            foreach (i, ext; enabledDevExts) devExtPtrs[i] = ext.toStringz();
            createInfo.enabledExtensionCount = cast(uint)devExtPtrs.length;
            createInfo.ppEnabledExtensionNames = devExtPtrs.ptr;
        }
        VkPhysicalDeviceFeatures enabledFeatures = VkPhysicalDeviceFeatures.init;
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
        VkCommandPoolCreateInfo info = VkCommandPoolCreateInfo.init;
        info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        info.queueFamilyIndex = graphicsQueueFamily;
        info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        enforce(vkCreateCommandPool(device, &info, null, &commandPool) == VK_SUCCESS,
            "Failed to create command pool");

        frameCommands.length = maxFramesInFlight;
        VkCommandBufferAllocateInfo allocInfo = VkCommandBufferAllocateInfo.init;
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocInfo.commandPool = commandPool;
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocInfo.commandBufferCount = cast(uint)frameCommands.length;
        enforce(vkAllocateCommandBuffers(device, &allocInfo, frameCommands.ptr) == VK_SUCCESS,
            "Failed to allocate command buffers");
    }

    void createSyncObjects() {
        VkSemaphoreCreateInfo semInfo = VkSemaphoreCreateInfo.init;
        semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        enforce(vkCreateSemaphore(device, &semInfo, null, &imageAvailable) == VK_SUCCESS,
            "Failed to create imageAvailable semaphore");
        enforce(vkCreateSemaphore(device, &semInfo, null, &renderFinished) == VK_SUCCESS,
            "Failed to create renderFinished semaphore");

        inFlightFences.length = maxFramesInFlight;
        VkFenceCreateInfo fenceInfo = VkFenceCreateInfo.init;
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

        VkSurfaceCapabilitiesKHR caps = VkSurfaceCapabilitiesKHR.init;
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

        VkSwapchainCreateInfoKHR ci = VkSwapchainCreateInfoKHR.init;
        ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        ci.surface = surface;
        ci.minImageCount = imageCount;
        ci.imageFormat = format.format;
        ci.imageColorSpace = format.colorSpace;
        ci.imageExtent = swapExtent;
        ci.imageArrayLayers = 1;
        ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

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
        if (debugSwapPipeline !is null) {
            vkDestroyPipeline(device, debugSwapPipeline, null);
            debugSwapPipeline = null;
        }
        if (descriptorPool !is null) {
            vkDestroyDescriptorPool(device, descriptorPool, null);
            descriptorPool = null;
        }
        if (pipelineLayout !is null) {
            vkDestroyPipelineLayout(device, pipelineLayout, null);
            pipelineLayout = null;
        }
        if (debugSwapPipelineLayout !is null) {
            vkDestroyPipelineLayout(device, debugSwapPipelineLayout, null);
            debugSwapPipelineLayout = null;
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
            VkImageViewCreateInfo info = VkImageViewCreateInfo.init;
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
        VkAttachmentDescription color = VkAttachmentDescription.init;
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

        VkSubpassDescription subpass = VkSubpassDescription.init;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorRef;

        VkSubpassDependency dep = VkSubpassDependency.init;
        dep.srcSubpass = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.srcAccessMask = 0;
        dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        VkRenderPassCreateInfo rp = VkRenderPassCreateInfo.init;
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
            VkFramebufferCreateInfo info = VkFramebufferCreateInfo.init;
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
            attachments[i].format = swapFormat; // swapchainと揃える
            attachments[i].samples = VK_SAMPLE_COUNT_1_BIT;
            attachments[i].loadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
            attachments[i].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
            attachments[i].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            attachments[i].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
            attachments[i].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            attachments[i].finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        }
        VkAttachmentDescription depth = VkAttachmentDescription.init;
        auto depthFmt = selectDepthFormat();
        depth.format = depthFmt;
        depth.samples = VK_SAMPLE_COUNT_1_BIT;
        depth.loadOp = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD;
        depth.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth.stencilLoadOp = depthAspect(depthFmt) & VK_IMAGE_ASPECT_STENCIL_BIT ? (clear ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD) : VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        depth.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        depth.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        VkAttachmentReference[3] colorRefs;
        colorRefs[0] = VkAttachmentReference(0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        colorRefs[1] = VkAttachmentReference(1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        colorRefs[2] = VkAttachmentReference(2, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
        VkAttachmentReference depthRef = VkAttachmentReference(3, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);

        VkSubpassDescription subpass = VkSubpassDescription.init;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 3;
        subpass.pColorAttachments = colorRefs.ptr;
        subpass.pDepthStencilAttachment = &depthRef;

        VkSubpassDependency dep = VkSubpassDependency.init;
        dep.srcSubpass = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dep.srcAccessMask = 0;
        dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        VkAttachmentDescription[4] allAttachments = [attachments[0], attachments[1], attachments[2], depth];
        VkRenderPassCreateInfo rp = VkRenderPassCreateInfo.init;
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
        VkFramebufferCreateInfo info = VkFramebufferCreateInfo.init;
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

        VkDescriptorPoolCreateInfo poolInfo = VkDescriptorPoolCreateInfo.init;
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

        VkDescriptorSetAllocateInfo alloc = VkDescriptorSetAllocateInfo.init;
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

        VkDescriptorBufferInfo globalsInfo = VkDescriptorBufferInfo.init;
        globalsInfo.buffer = globalsUbo.buffer;
        globalsInfo.offset = 0;
        globalsInfo.range = globalsUbo.size;

        VkDescriptorBufferInfo paramsInfo = VkDescriptorBufferInfo.init;
        paramsInfo.buffer = paramsUbo.buffer;
        paramsInfo.offset = 0;
        paramsInfo.range = paramsUbo.size;

        VkWriteDescriptorSet[2] writes;
        foreach (ref w; writes) w = VkWriteDescriptorSet.init;
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
    void ensureReadbackBuffer(size_t sz) {
        if (debugReadbackBuffer.buffer !is null && debugReadbackBuffer.size >= sz) return;
        destroyBuffer(debugReadbackBuffer);
        debugReadbackBuffer = createBuffer(sz,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    }

    /// デバッグ矩形用 1px RGBA をホスト可視バッファに用意
    void ensureDebugRectBuffer(uint width, uint height, ubyte r, ubyte g, ubyte b, ubyte a) {
        size_t sz = cast(size_t)width * cast(size_t)height * 4;
        if (sz == 0) sz = 4;
        if (debugRectBuffer.buffer is null || debugRectBuffer.size < sz) {
            destroyBuffer(debugRectBuffer);
            debugRectBuffer = createBuffer(sz, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        }
        if (debugRectBuffer.memory !is null) {
            void* ptr;
            if (vkMapMemory(device, debugRectBuffer.memory, 0, sz, 0, &ptr) == VK_SUCCESS) {
                auto dst = (cast(ubyte*)ptr)[0 .. sz];
                foreach (i; 0 .. width * height) {
                    auto idx = i * 4;
                    dst[idx] = r;
                    dst[idx + 1] = g;
                    dst[idx + 2] = b;
                    dst[idx + 3] = a;
                }
                vkUnmapMemory(device, debugRectBuffer.memory);
            }
        }
    }

    void createCompositeBuffers() {
        // recreate all transient quad/composite buffers
        destroyBuffer(compositePosBuffer);
        destroyBuffer(compositeUvBuffer);
        destroyBuffer(quadPosXBuffer);
        destroyBuffer(quadPosYBuffer);
        destroyBuffer(quadUvXBuffer);
        destroyBuffer(quadUvYBuffer);
        destroyBuffer(quadDeformXBuffer);
        destroyBuffer(quadDeformYBuffer);

        float[6] zeros = [0, 0, 0, 0, 0, 0];
        uploadBufferData(quadDeformXBuffer, zeros[]);
        uploadBufferData(quadDeformYBuffer, zeros[]);
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
        mainAlbedo = createImage(extent, swapFormat,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            VK_IMAGE_ASPECT_COLOR_BIT, 1);
        mainEmissive = createImage(extent, swapFormat,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            VK_IMAGE_ASPECT_COLOR_BIT, 1);
        mainBump = createImage(extent, swapFormat,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            VK_IMAGE_ASPECT_COLOR_BIT, 1);
        auto depthFmt = selectDepthFormat();
        mainDepth = createImage(extent, depthFmt,
            VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            depthAspect(depthFmt), 1);

        offscreenRenderPass = createOffscreenRenderPass(true);
        offscreenRenderPassLoad = createOffscreenRenderPass(false);
        createOffscreenFramebuffer();
        imagesInitialized = false;
    }

    GpuImage createImage(VkExtent2D extent, VkFormat format, VkImageUsageFlags usage, VkImageAspectFlags aspect, uint mipLevels) {
        GpuImage img;
        img.format = format;
        img.extent = extent;
        img.aspect = aspect;
        img.mipLevels = mipLevels > 0 ? mipLevels : 1;

        VkImageCreateInfo ci = VkImageCreateInfo.init;
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

        VkMemoryRequirements req = VkMemoryRequirements.init;
        vkGetImageMemoryRequirements(device, img.image, &req);

        VkMemoryAllocateInfo alloc = VkMemoryAllocateInfo.init;
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.allocationSize = req.size;
        alloc.memoryTypeIndex = findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        enforce(vkAllocateMemory(device, &alloc, null, &img.memory) == VK_SUCCESS,
            "Failed to allocate image memory");
        vkBindImageMemory(device, img.image, img.memory, 0);

        VkImageViewCreateInfo view = VkImageViewCreateInfo.init;
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
        VkPhysicalDeviceMemoryProperties memProps = VkPhysicalDeviceMemoryProperties.init;
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
        VkBufferCreateInfo info = VkBufferCreateInfo.init;
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        enforce(vkCreateBuffer(device, &info, null, &buf.buffer) == VK_SUCCESS,
            "Failed to create buffer");
        VkMemoryRequirements req = VkMemoryRequirements.init;
        vkGetBufferMemoryRequirements(device, buf.buffer, &req);
        VkMemoryAllocateInfo alloc = VkMemoryAllocateInfo.init;
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
        VkBufferCopy region = VkBufferCopy.init;
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
        VkBufferImageCopy region = VkBufferImageCopy.init;
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

    void createDebugSolidTextures() {
        destroyTextureHandle(debugWhiteTex);
        destroyTextureHandle(debugBlackTex);
        debugWhiteTex = cast(VkTextureHandle)createTextureHandle();
        debugBlackTex = cast(VkTextureHandle)createTextureHandle();
        ubyte[4] white = [255, 255, 255, 255];
        ubyte[4] black = [0, 0, 0, 255];
        uploadTextureData(debugWhiteTex, 1, 1, 4, 4, false, white[]);
        uploadTextureData(debugBlackTex, 1, 1, 4, 4, false, black[]);
    }

    VkCommandBuffer beginSingleTimeCommands() {
        VkCommandBufferAllocateInfo alloc = VkCommandBufferAllocateInfo.init;
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.commandPool = commandPool;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = 1;
        VkCommandBuffer cmd;
        enforce(vkAllocateCommandBuffers(device, &alloc, &cmd) == VK_SUCCESS,
            "Failed to allocate command buffer");

        VkCommandBufferBeginInfo begin = VkCommandBufferBeginInfo.init;
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(cmd, &begin);
        return cmd;
    }

    void endSingleTimeCommands(VkCommandBuffer cmd) {
        vkEndCommandBuffer(cmd);
        VkSubmitInfo submit = VkSubmitInfo.init;
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
        foreach (ref b; bindings) b = VkDescriptorSetLayoutBinding.init;
        bindings[0].binding = 0;
        bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;

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

        VkDescriptorSetLayoutCreateInfo info = VkDescriptorSetLayoutCreateInfo.init;
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        info.bindingCount = 5;
        info.pBindings = bindings.ptr;
        enforce(vkCreateDescriptorSetLayout(device, &info, null, &descriptorSetLayout) == VK_SUCCESS,
            "Failed to create descriptor set layout");
    }

    void createPipelineLayout() {
        VkPipelineLayoutCreateInfo info = VkPipelineLayoutCreateInfo.init;
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

        VkVertexInputBindingDescription[6] bindings;
        foreach (i; 0 .. bindings.length) {
            bindings[i].binding = cast(uint)i;
            bindings[i].stride = float.sizeof;
            bindings[i].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        }

        VkVertexInputAttributeDescription[6] attrs;
        attrs[0] = VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32_SFLOAT, 0); // vertX
        attrs[1] = VkVertexInputAttributeDescription(1, 1, VK_FORMAT_R32_SFLOAT, 0); // vertY
        attrs[2] = VkVertexInputAttributeDescription(2, 2, VK_FORMAT_R32_SFLOAT, 0); // uvX
        attrs[3] = VkVertexInputAttributeDescription(3, 3, VK_FORMAT_R32_SFLOAT, 0); // uvY
        attrs[4] = VkVertexInputAttributeDescription(4, 4, VK_FORMAT_R32_SFLOAT, 0); // deformX
        attrs[5] = VkVertexInputAttributeDescription(5, 5, VK_FORMAT_R32_SFLOAT, 0); // deformY

        VkPipelineVertexInputStateCreateInfo vi = VkPipelineVertexInputStateCreateInfo.init;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = cast(uint)bindings.length;
        vi.pVertexBindingDescriptions = bindings.ptr;
        vi.vertexAttributeDescriptionCount = cast(uint)attrs.length;
        vi.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia = VkPipelineInputAssemblyStateCreateInfo.init;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        ia.primitiveRestartEnable = VK_FALSE;

        VkPipelineViewportStateCreateInfo vp = VkPipelineViewportStateCreateInfo.init;
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
        VkPipelineDynamicStateCreateInfo dyn = VkPipelineDynamicStateCreateInfo.init;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkPipelineRasterizationStateCreateInfo rs = VkPipelineRasterizationStateCreateInfo.init;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.depthClampEnable = VK_FALSE;
        rs.rasterizerDiscardEnable = VK_FALSE;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.depthBiasEnable = VK_FALSE;

        VkPipelineMultisampleStateCreateInfo ms = VkPipelineMultisampleStateCreateInfo.init;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState[3] blendAtt;
        foreach (i; 0 .. 3) {
            fillBlendAttachment(blendAtt[i]);
        }
        VkPipelineColorBlendStateCreateInfo blend = VkPipelineColorBlendStateCreateInfo.init;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = cast(uint)blendAtt.length;
        blend.pAttachments = blendAtt.ptr;

        VkPipelineDepthStencilStateCreateInfo ds = VkPipelineDepthStencilStateCreateInfo.init;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        // 2D用途のため深度は無効化して描画漏れを防ぐ
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        ds.depthCompareOp = VK_COMPARE_OP_ALWAYS;
        ds.depthBoundsTestEnable = VK_FALSE;
        ds.stencilTestEnable = enableStencilTest ? VK_TRUE : VK_FALSE;
        ds.front = VkStencilOpState(VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
            enableStencilTest ? VK_COMPARE_OP_EQUAL : VK_COMPARE_OP_ALWAYS, 0xFF, 0xFF, 1);
        ds.back = ds.front;

        VkGraphicsPipelineCreateInfo gp = VkGraphicsPipelineCreateInfo.init;
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

        VkVertexInputBindingDescription[4] bindings;
        foreach (i; 0 .. bindings.length) {
            bindings[i].binding = cast(uint)i;
            bindings[i].stride = float.sizeof;
            bindings[i].inputRate = VK_VERTEX_INPUT_RATE_VERTEX;
        }

        VkVertexInputAttributeDescription[4] attrs;
        attrs[0] = VkVertexInputAttributeDescription(0, 0, VK_FORMAT_R32_SFLOAT, 0); // vertX
        attrs[1] = VkVertexInputAttributeDescription(1, 1, VK_FORMAT_R32_SFLOAT, 0); // vertY
        attrs[2] = VkVertexInputAttributeDescription(2, 2, VK_FORMAT_R32_SFLOAT, 0); // deformX
        attrs[3] = VkVertexInputAttributeDescription(3, 3, VK_FORMAT_R32_SFLOAT, 0); // deformY

        VkPipelineVertexInputStateCreateInfo vi = VkPipelineVertexInputStateCreateInfo.init;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = cast(uint)bindings.length;
        vi.pVertexBindingDescriptions = bindings.ptr;
        vi.vertexAttributeDescriptionCount = cast(uint)attrs.length;
        vi.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia = VkPipelineInputAssemblyStateCreateInfo.init;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        ia.primitiveRestartEnable = VK_FALSE;

        VkPipelineViewportStateCreateInfo vp = VkPipelineViewportStateCreateInfo.init;
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
        VkPipelineDynamicStateCreateInfo dyn = VkPipelineDynamicStateCreateInfo.init;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkPipelineRasterizationStateCreateInfo rs = VkPipelineRasterizationStateCreateInfo.init;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

        VkPipelineMultisampleStateCreateInfo ms = VkPipelineMultisampleStateCreateInfo.init;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState[3] blendAtt;
        foreach (i; 0 .. 3) {
            blendAtt[i] = VkPipelineColorBlendAttachmentState.init;
            blendAtt[i].colorWriteMask = 0; // Mask writes only touch stencil
            blendAtt[i].blendEnable = VK_FALSE;
        }
        VkPipelineColorBlendStateCreateInfo blend = VkPipelineColorBlendStateCreateInfo.init;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 3;
        blend.pAttachments = blendAtt.ptr;

        VkPipelineDepthStencilStateCreateInfo ds = VkPipelineDepthStencilStateCreateInfo.init;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        ds.depthCompareOp = VK_COMPARE_OP_ALWAYS;
        ds.stencilTestEnable = VK_TRUE;
        ds.front = VkStencilOpState(VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_REPLACE,
            VK_COMPARE_OP_ALWAYS, 0xFF, 0xFF, 1);
        ds.back = ds.front;

        VkGraphicsPipelineCreateInfo gp = VkGraphicsPipelineCreateInfo.init;
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

        VkPipelineVertexInputStateCreateInfo vi = VkPipelineVertexInputStateCreateInfo.init;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = 2;
        vi.pVertexBindingDescriptions = bindings.ptr;
        vi.vertexAttributeDescriptionCount = 2;
        vi.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia = VkPipelineInputAssemblyStateCreateInfo.init;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        ia.primitiveRestartEnable = VK_FALSE;

        VkPipelineViewportStateCreateInfo vp = VkPipelineViewportStateCreateInfo.init;
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
        VkPipelineDynamicStateCreateInfo dyn = VkPipelineDynamicStateCreateInfo.init;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkPipelineRasterizationStateCreateInfo rs = VkPipelineRasterizationStateCreateInfo.init;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

        VkPipelineMultisampleStateCreateInfo ms = VkPipelineMultisampleStateCreateInfo.init;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState[3] blendAtt;
        foreach (i; 0 .. 3) {
            blendAtt[i] = VkPipelineColorBlendAttachmentState.init;
            fillBlendAttachment(blendAtt[i]);
        }
        VkPipelineColorBlendStateCreateInfo blend = VkPipelineColorBlendStateCreateInfo.init;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 3;
        blend.pAttachments = blendAtt.ptr;

        VkPipelineDepthStencilStateCreateInfo ds = VkPipelineDepthStencilStateCreateInfo.init;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        ds.depthCompareOp = VK_COMPARE_OP_ALWAYS;
        ds.stencilTestEnable = enableStencilTest ? VK_TRUE : VK_FALSE;
        ds.front = VkStencilOpState(VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
            enableStencilTest ? VK_COMPARE_OP_EQUAL : VK_COMPARE_OP_ALWAYS, 0xFF, 0xFF, 1);
        ds.back = ds.front;

        VkGraphicsPipelineCreateInfo gp = VkGraphicsPipelineCreateInfo.init;
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

    void createDebugSwapPipeline() {
        if (renderPass is null) return;
        if (debugSwapPipeline !is null) {
            vkDestroyPipeline(device, debugSwapPipeline, null);
            debugSwapPipeline = null;
        }
        if (debugSwapPipelineLayout !is null) {
            vkDestroyPipelineLayout(device, debugSwapPipelineLayout, null);
            debugSwapPipelineLayout = null;
        }

        VkPipelineLayoutCreateInfo layoutInfo = VkPipelineLayoutCreateInfo.init;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 0;
        layoutInfo.pSetLayouts = null;
        enforce(vkCreatePipelineLayout(device, &layoutInfo, null, &debugSwapPipelineLayout) == VK_SUCCESS,
            "Failed to create debug swap pipeline layout");

        auto vertSpv = compileGlslToSpirv("debug_swap.vert", "", ".vert");
        auto fragSpv = compileGlslToSpirv("debug_swap.frag", "", ".frag");
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

        VkPipelineVertexInputStateCreateInfo vi = VkPipelineVertexInputStateCreateInfo.init;
        vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        VkPipelineInputAssemblyStateCreateInfo ia = VkPipelineInputAssemblyStateCreateInfo.init;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        VkViewport viewport = VkViewport(0, 0, cast(float)swapExtent.width, cast(float)swapExtent.height, 0.0f, 1.0f);
        VkRect2D scissor = VkRect2D(VkOffset2D(0, 0), VkExtent2D(swapExtent.width, swapExtent.height));
        VkPipelineViewportStateCreateInfo vp = VkPipelineViewportStateCreateInfo.init;
        vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1;
        vp.pViewports = &viewport;
        vp.scissorCount = 1;
        vp.pScissors = &scissor;

        VkPipelineRasterizationStateCreateInfo rs = VkPipelineRasterizationStateCreateInfo.init;
        rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = VK_POLYGON_MODE_FILL;
        rs.cullMode = VK_CULL_MODE_NONE;
        rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

        VkPipelineMultisampleStateCreateInfo ms = VkPipelineMultisampleStateCreateInfo.init;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState blendAtt = VkPipelineColorBlendAttachmentState.init;
        blendAtt.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        blendAtt.blendEnable = VK_FALSE;

        VkPipelineColorBlendStateCreateInfo blend = VkPipelineColorBlendStateCreateInfo.init;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 1;
        blend.pAttachments = &blendAtt;

        VkPipelineDepthStencilStateCreateInfo ds = VkPipelineDepthStencilStateCreateInfo.init;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;

        VkDynamicState[2] dynStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dyn = VkPipelineDynamicStateCreateInfo.init;
        dyn.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn.dynamicStateCount = dynStates.length;
        dyn.pDynamicStates = dynStates.ptr;

        VkGraphicsPipelineCreateInfo gp = VkGraphicsPipelineCreateInfo.init;
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
        gp.layout = debugSwapPipelineLayout;
        gp.renderPass = renderPass;
        gp.subpass = 0;

        enforce(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &gp, null, &debugSwapPipeline) == VK_SUCCESS,
            "Failed to create debug swap pipeline");
    }

    void recreatePipelines() {
        createBasicPipeline(false, basicPipeline);
        createBasicPipeline(true, basicMaskedPipeline);
        createMaskPipeline();
        createCompositePipeline(false, compositePipeline);
        createCompositePipeline(true, compositeMaskedPipeline);
        createDebugSwapPipeline();
    }

    size_t pixelSizeForFormat(VkFormat format) {
        switch (format) {
            case VK_FORMAT_R8_UNORM: return 1;
            case VK_FORMAT_R8G8B8A8_UNORM: return 4;
            case VK_FORMAT_D24_UNORM_S8_UINT: return 4;
            case VK_FORMAT_D32_SFLOAT: return 4;
            case VK_FORMAT_D32_SFLOAT_S8_UINT: return 8;
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
        VkSamplerCreateInfo samplerInfo = VkSamplerCreateInfo.init;
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
        VkImageMemoryBarrier barrier = VkImageMemoryBarrier.init;
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
        // Set access masks based on layouts
        switch (oldLayout) {
            case VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL:
                barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                srcStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
                break;
            case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
                barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
                srcStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
                break;
            case VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
                barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                srcStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
                break;
            default:
                barrier.srcAccessMask = 0;
                srcStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
                break;
        }
        switch (newLayout) {
            case VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
                barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                dstStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
                break;
            case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
                barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
                dstStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
                break;
            case VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL:
                barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
                dstStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
                break;
            case VK_IMAGE_LAYOUT_PRESENT_SRC_KHR:
                barrier.dstAccessMask = 0;
                dstStage = VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
                break;
            default:
                barrier.dstAccessMask = 0;
                dstStage = VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
                break;
        }
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
        VkShaderModuleCreateInfo info = VkShaderModuleCreateInfo.init;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = spirv.length;
        info.pCode = cast(uint*)spirv.ptr;
        VkShaderModule handle;
        enforce(vkCreateShaderModule(device, &info, null, &handle) == VK_SUCCESS,
            "Failed to create shader module");
        return handle;
    }

    const(ubyte)[] compileGlslToSpirv(string logicalName, string source, string stageExt) {
        // Embed known shaders via string imports (shaders/ is on stringImportPaths).
        switch (logicalName) {
            case "basic.vert":             return cast(const(ubyte)[])import("vulkan/compiled/basic.vert.spv");
            case "basic.frag":             return cast(const(ubyte)[])import("vulkan/compiled/basic.frag.spv");
            case "mask.vert":              return cast(const(ubyte)[])import("vulkan/compiled/mask.vert.spv");
            case "mask.frag":              return cast(const(ubyte)[])import("vulkan/compiled/mask.frag.spv");
            case "basic/composite.vert":   return cast(const(ubyte)[])import("vulkan/compiled/composite.vert.spv");
            case "basic/composite.frag":   return cast(const(ubyte)[])import("vulkan/compiled/composite.frag.spv");
            case "composite.vert":         return cast(const(ubyte)[])import("vulkan/compiled/composite.vert.spv");
            case "composite.frag":         return cast(const(ubyte)[])import("vulkan/compiled/composite.frag.spv");
            case "debug_swap.vert":        return cast(const(ubyte)[])import("vulkan/debug/compiled/debug_swap.vert.spv");
            case "debug_swap.frag":        return cast(const(ubyte)[])import("vulkan/debug/compiled/debug_swap.frag.spv");
            default:
                enforce(false, "Precompiled SPIR-V not embedded for "~logicalName);
        }
        assert(0);
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
        destroyTextureHandle(debugWhiteTex);
        destroyTextureHandle(debugBlackTex);
        destroyBuffer(sharedVertexBuffer);
        destroyBuffer(sharedUvBuffer);
        destroyBuffer(sharedDeformBuffer);
        destroyBuffer(compositePosBuffer);
        destroyBuffer(compositeUvBuffer);
        destroyBuffer(quadPosXBuffer);
        destroyBuffer(quadPosYBuffer);
        destroyBuffer(quadUvXBuffer);
        destroyBuffer(quadUvYBuffer);
        destroyBuffer(quadDeformXBuffer);
        destroyBuffer(quadDeformYBuffer);
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
        if (debugSwapPipeline !is null) {
            vkDestroyPipeline(device, debugSwapPipeline, null);
            debugSwapPipeline = null;
        }
        if (descriptorPool !is null) {
            vkDestroyDescriptorPool(device, descriptorPool, null);
            descriptorPool = null;
        }
        if (pipelineLayout !is null) {
            vkDestroyPipelineLayout(device, pipelineLayout, null);
            pipelineLayout = null;
        }
        if (debugSwapPipelineLayout !is null) {
            vkDestroyPipelineLayout(device, debugSwapPipelineLayout, null);
            debugSwapPipelineLayout = null;
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
