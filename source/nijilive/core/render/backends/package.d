module nijilive.core.render.backends;

import nijilive.core.nodes : Node;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.render.commands : PartDrawPacket;

/// GPU周りの共有状態を Backend がキャッシュするための構造体
struct RenderGpuState {
    uint framebuffer;
    uint[8] drawBuffers;
    ubyte drawBufferCount;
    bool[4] colorMask;
    bool blendEnabled;
}

/// Backend abstraction executed by RenderCommand implementations.
interface RenderBackend {
    void drawNode(Node node);
    void drawPartPacket(ref PartDrawPacket packet);
    void drawCompositeRaw(Composite composite);
    void drawCompositeMask(Composite composite, Part[] masks);
}
