module nijilive.core.render.queue;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;

import nijilive.core.render.backends : RenderBackend, RenderGpuState;
import nijilive.core.render.commands;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;

/// Render target scope kinds.
enum RenderPassKind {
    Root,
    Composite,
    DynamicComposite,
}

struct RenderScopeHint {
    RenderPassKind kind = RenderPassKind.Root;
    Composite composite;
    DynamicComposite dynamicComposite;
    bool skip;

    static RenderScopeHint root() {
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Root;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint forComposite(Composite composite) {
        if (composite is null) return root();
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Composite;
        hint.composite = composite;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint forDynamic(DynamicComposite composite) {
        if (composite is null) return root();
        RenderScopeHint hint;
        hint.kind = RenderPassKind.DynamicComposite;
        hint.dynamicComposite = composite;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint skipHint() {
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Root;
        hint.skip = true;
        return hint;
    }
}

/// Helper used by enqueueItem to bundle commands before registering them.
struct RenderCommandBuffer {
    RenderCommandData[] commands;

    void add(RenderCommandData command) {
        commands ~= command;
    }

    void addAll(RenderCommandData[] more) {
        commands ~= more;
    }
}

private struct RenderItem {
    float zSort;
    size_t sequence;
    RenderCommandData[] commands;
}

private struct RenderPass {
    RenderPassKind kind;
    Composite composite;
    DynamicComposite dynamicComposite;
    bool maskUsesStencil;
    MaskApplyPacket[] maskPackets;
    RenderItem[] items;
    size_t nextSequence;
    size_t token;
    void delegate(ref RenderCommandBuffer) dynamicPostCommands;
    bool enqueueImmediate;
}

/// Layered render queue that groups commands per render target scope.
final class RenderQueue {
private:
    RenderPass[] passStack;
    size_t nextToken;

    void ensureRootPass() {
        if (passStack.length == 0) {
            RenderPass root;
            root.kind = RenderPassKind.Root;
            root.token = 0;
            root.nextSequence = 0;
            passStack ~= root;
        }
    }

    ref RenderPass currentPass() {
        ensureRootPass();
        return passStack[$ - 1];
    }

    static bool itemLess(ref RenderItem a, ref RenderItem b) {
        if (a.zSort == b.zSort) {
            return a.sequence < b.sequence;
        }
        return a.zSort > b.zSort; // 降順 (zSort が大きいものを先に処理)
    }

    RenderCommandData[] collectPassCommands(ref RenderPass pass) {
        if (pass.items.length == 0) return [];
        pass.items.sort!itemLess();
        RenderCommandData[] flattened;
        foreach (item; pass.items) {
            flattened ~= item.commands;
        }
        return flattened;
    }

    void addItemToPass(ref RenderPass pass, float zSort, RenderCommandData[] commands) {
        if (commands.length == 0) return;
        RenderItem item;
        item.zSort = zSort;
        item.sequence = pass.nextSequence++;
        item.commands = commands;
        pass.items ~= item;
    }

    void finalizeCompositePass(bool autoClose) {
        enforce(passStack.length > 1, "RenderQueue: cannot finalize composite scope without active pass. " ~ stackDebugString());
        auto pass = passStack[$ - 1];
        enforce(pass.kind == RenderPassKind.Composite, "RenderQueue: top scope is not composite. " ~ stackDebugString());
        size_t parentIndex = parentPassIndexForComposite(pass.composite);
        passStack.length -= 1;

        auto childCommands = collectPassCommands(pass);

        RenderCommandBuffer compositeBuffer;
        compositeBuffer.add(makeBeginCompositeCommand());
        compositeBuffer.addAll(childCommands);
        compositeBuffer.add(makeEndCompositeCommand());

        if (pass.maskPackets.length > 0 || pass.maskUsesStencil) {
            compositeBuffer.add(makeBeginMaskCommand(pass.maskUsesStencil));
            foreach (packet; pass.maskPackets) {
                compositeBuffer.add(makeApplyMaskCommand(packet));
            }
            compositeBuffer.add(makeBeginMaskContentCommand());
        }

        compositeBuffer.add(makeDrawCompositeQuadCommand(makeCompositeDrawPacket(pass.composite)));

        if (pass.maskPackets.length > 0 || pass.maskUsesStencil) {
            compositeBuffer.add(makeEndMaskCommand());
        }

        addItemToPass(passStack[parentIndex], pass.composite ? pass.composite.zSort() : 0, compositeBuffer.commands.dup);

        if (autoClose && pass.composite !is null) {
            pass.composite.markCompositeScopeClosed();
        }
    }

    void finalizeDynamicCompositePass(bool autoClose, scope void delegate(ref RenderCommandBuffer) postCommands = null) {
        enforce(passStack.length > 1, "RenderQueue: cannot finalize dynamic composite scope without active pass. " ~ stackDebugString());
        auto pass = passStack[$ - 1];
        enforce(pass.kind == RenderPassKind.DynamicComposite, "RenderQueue: top scope is not dynamic composite. " ~ stackDebugString());
        size_t parentIndex = parentPassIndexForDynamic(pass.dynamicComposite);
        passStack.length -= 1;

        auto childCommands = collectPassCommands(pass);

        RenderCommandBuffer buffer;
        buffer.add(makeBeginDynamicCompositeCommand(pass.dynamicComposite));
        buffer.addAll(childCommands);
        buffer.add(makeEndDynamicCompositeCommand(pass.dynamicComposite));

        auto finalizer = postCommands is null ? pass.dynamicPostCommands : postCommands;
        if (finalizer !is null) {
            finalizer(buffer);
        }

        addItemToPass(passStack[parentIndex], pass.dynamicComposite ? pass.dynamicComposite.zSort() : 0, buffer.commands.dup);

        if (pass.dynamicComposite !is null) {
            pass.dynamicComposite.dynamicScopeActive = false;
            pass.dynamicComposite.dynamicScopeToken = size_t.max;
        }
        pass.dynamicPostCommands = null;
    }

    void finalizeTopPass(bool autoClose) {
        enforce(passStack.length > 1, "RenderQueue: no scope available to finalize. " ~ stackDebugString());
        auto pass = passStack[$ - 1];
        final switch (pass.kind) {
            case RenderPassKind.Composite:
                finalizeCompositePass(autoClose);
                break;
            case RenderPassKind.DynamicComposite:
                finalizeDynamicCompositePass(autoClose, null);
                break;
            case RenderPassKind.Root:
                enforce(false, "RenderQueue: cannot finalize root pass.");
        }
    }

    string stackDebugString() const {
        import std.array : appender;
        import std.format : formattedWrite;
        auto buf = appender!string();
        buf.formattedWrite("[stack depth=%s]", passStack.length);
        foreach (i, pass; passStack) {
            buf.formattedWrite(" #%s(kind=%s,token=%s,ptr=%s)",
                i,
                pass.kind,
                pass.token,
                (pass.kind == RenderPassKind.Composite && pass.composite !is null)
                    ? cast(void*)pass.composite
                    : pass.kind == RenderPassKind.DynamicComposite && pass.dynamicComposite !is null
                        ? cast(void*)pass.dynamicComposite
                        : cast(void*)null);
        }
        return buf.data;
    }

    size_t findPassIndex(size_t token, RenderPassKind kind) const {
        if (passStack.length <= 1) return 0;
        for (size_t idx = passStack.length; idx > 0; --idx) {
            auto pass = passStack[idx - 1];
            if (pass.token == token && pass.kind == kind) {
                return idx - 1;
            }
        }
        return 0;
    }

    size_t findPassIndex(Composite composite, RenderPassKind kind) const {
        if (composite is null) return 0;
        for (size_t idx = passStack.length; idx > 0; --idx) {
            auto pass = passStack[idx - 1];
            if (pass.kind == kind && pass.composite is composite) {
                return idx - 1;
            }
        }
        return 0;
    }

    size_t findPassIndex(DynamicComposite composite, RenderPassKind kind) const {
        if (composite is null) return 0;
        for (size_t idx = passStack.length; idx > 0; --idx) {
            auto pass = passStack[idx - 1];
            if (pass.kind == kind && pass.dynamicComposite is composite) {
                return idx - 1;
            }
        }
        return 0;
    }

    size_t parentPassIndexForComposite(Composite composite) {
        if (composite is null || passStack.length == 0) return 0;
        auto ancestor = composite.parent;
        while (ancestor !is null) {
            if (auto dyn = cast(DynamicComposite)ancestor) {
                auto idx = findPassIndex(dyn, RenderPassKind.DynamicComposite);
                if (idx > 0) return idx;
            }
            if (auto comp = cast(Composite)ancestor) {
                auto idx = findPassIndex(comp, RenderPassKind.Composite);
                if (idx > 0) return idx;
            }
            ancestor = ancestor.parent;
        }
        return 0;
    }

    size_t parentPassIndexForDynamic(DynamicComposite composite) {
        if (composite is null || passStack.length == 0) return 0;
        auto ancestor = composite.parent;
        while (ancestor !is null) {
            if (auto dyn = cast(DynamicComposite)ancestor) {
                auto idx = findPassIndex(dyn, RenderPassKind.DynamicComposite);
                if (idx > 0) return idx;
            }
            if (auto comp = cast(Composite)ancestor) {
                auto idx = findPassIndex(comp, RenderPassKind.Composite);
                if (idx > 0) return idx;
            }
            ancestor = ancestor.parent;
        }
        return 0;
    }

public:
    this() {
        ensureRootPass();
    }

    void beginFrame() {
        clear();
    }

    void clear() {
        passStack.length = 0;
        nextToken = 0;
        ensureRootPass();
    }

    bool empty() const {
        if (passStack.length == 0) return true;
        if (passStack.length == 1) {
            return passStack[0].items.length == 0;
        }
        return false;
    }

    void enqueue(RenderCommandData command) {
        enqueueItem(0, RenderScopeHint.root(), (ref RenderCommandBuffer buffer) {
            buffer.add(command);
        });
    }

    ref RenderPass resolvePass(RenderScopeHint hint) {
        ensureRootPass();
        size_t index = 0;
        final switch (hint.kind) {
            case RenderPassKind.Root:
                index = 0;
                break;
            case RenderPassKind.Composite:
                index = findPassIndex(hint.composite, RenderPassKind.Composite);
                enforce(index > 0, "RenderQueue: composite scope not active for enqueue. " ~ stackDebugString());
                break;
            case RenderPassKind.DynamicComposite:
                index = findPassIndex(hint.dynamicComposite, RenderPassKind.DynamicComposite);
                enforce(index > 0, "RenderQueue: dynamic composite scope not active for enqueue. " ~ stackDebugString());
                break;
        }
        return passStack[index];
    }

    void enqueueItem(float zSort, scope void delegate(ref RenderCommandBuffer) builder) {
        enqueueItem(zSort, RenderScopeHint.root(), builder);
    }

    void enqueueItem(float zSort, RenderScopeHint hint, scope void delegate(ref RenderCommandBuffer) builder) {
        RenderCommandBuffer buffer;
        builder(buffer);
        auto ref pass = resolvePass(hint);
        addItemToPass(pass, zSort, buffer.commands.dup);
    }

    size_t pushComposite(Composite composite, bool maskUsesStencil, MaskApplyPacket[] maskPackets) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.Composite;
        pass.composite = composite;
        pass.maskUsesStencil = maskUsesStencil;
        pass.maskPackets = maskPackets.dup;
        pass.token = ++nextToken;
        pass.nextSequence = 0;
        pass.dynamicPostCommands = null;
        passStack ~= pass;
        return pass.token;
    }

    void popComposite(size_t token, Composite composite) {
        enforce(passStack.length > 1, "RenderQueue.popComposite called without matching push. " ~ stackDebugString());
        auto targetIndex = findPassIndex(token, RenderPassKind.Composite);
        enforce(targetIndex > 0, "RenderQueue.popComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());

        while (passStack.length - 1 > targetIndex) {
            finalizeTopPass(true);
        }

        auto pass = passStack[$ - 1];
        enforce(pass.composite is composite,
            "RenderQueue.popComposite scope mismatch (ptr=" ~ (cast(void*)pass.composite).to!string ~ ", expected=" ~ (cast(void*)composite).to!string ~ ") " ~ stackDebugString());

        finalizeCompositePass(false);
    }

    size_t pushDynamicComposite(DynamicComposite composite) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.DynamicComposite;
        pass.dynamicComposite = composite;
        pass.token = ++nextToken;
        pass.nextSequence = 0;
        pass.dynamicPostCommands = null;
        passStack ~= pass;
        return pass.token;
    }

    void popDynamicComposite(size_t token, DynamicComposite composite, scope void delegate(ref RenderCommandBuffer) postCommands = null) {
        enforce(passStack.length > 1, "RenderQueue.popDynamicComposite called without matching push. " ~ stackDebugString());
        auto targetIndex = findPassIndex(token, RenderPassKind.DynamicComposite);
        enforce(targetIndex > 0, "RenderQueue.popDynamicComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());

        if (postCommands !is null) {
            passStack[targetIndex].dynamicPostCommands = postCommands;
        }

        while (passStack.length - 1 > targetIndex) {
            finalizeTopPass(true);
        }

        auto pass = passStack[$ - 1];
        enforce(pass.dynamicComposite is composite,
            "RenderQueue.popDynamicComposite scope mismatch (ptr=" ~ (cast(void*)pass.dynamicComposite).to!string ~ ", expected=" ~ (cast(void*)composite).to!string ~ ") " ~ stackDebugString());

        finalizeDynamicCompositePass(false, postCommands);
        if (composite !is null) {
            composite.dynamicScopeActive = false;
            composite.dynamicScopeToken = size_t.max;
        }
    }

    void flush(RenderBackend backend, ref RenderGpuState state) {
        if (backend is null) {
            clear();
            return;
        }

        enforce(passStack.length == 1, "RenderQueue scopes were not balanced before flush. " ~ stackDebugString());

        state = RenderGpuState.init;
        auto commands = collectPassCommands(passStack[0]);

        foreach (ref command; commands) {
            final switch (command.kind) {
                case RenderCommandKind.DrawNode:
                    if (command.node !is null) backend.drawNode(command.node);
                    break;
                case RenderCommandKind.DrawPart:
                    backend.drawPartPacket(command.partPacket);
                    break;
                case RenderCommandKind.DrawMask:
                    backend.drawMaskPacket(command.maskDrawPacket);
                    break;
                case RenderCommandKind.BeginDynamicComposite:
                    if (command.dynamicComposite !is null) backend.beginDynamicComposite(command.dynamicComposite);
                    break;
                case RenderCommandKind.EndDynamicComposite:
                    if (command.dynamicComposite !is null) backend.endDynamicComposite(command.dynamicComposite);
                    break;
                case RenderCommandKind.BeginMask:
                    backend.beginMask(command.maskUsesStencil);
                    break;
                case RenderCommandKind.ApplyMask:
                    backend.applyMask(command.maskPacket);
                    break;
                case RenderCommandKind.BeginMaskContent:
                    backend.beginMaskContent();
                    break;
                case RenderCommandKind.EndMask:
                    backend.endMask();
                    break;
                case RenderCommandKind.BeginComposite:
                    backend.beginComposite();
                    break;
                case RenderCommandKind.DrawCompositeQuad:
                    backend.drawCompositeQuad(command.compositePacket);
                    break;
                case RenderCommandKind.EndComposite:
                    backend.endComposite();
                    break;
            }
        }

        clear();
    }
}
