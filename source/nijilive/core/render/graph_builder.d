module nijilive.core.render.graph_builder;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;

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
    size_t token;
    bool skip;

    static RenderScopeHint root() {
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Root;
        hint.token = 0;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint forComposite(size_t token) {
        if (token == 0 || token == size_t.max) return root();
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Composite;
        hint.token = token;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint forDynamic(size_t token) {
        if (token == 0 || token == size_t.max) return root();
        RenderScopeHint hint;
        hint.kind = RenderPassKind.DynamicComposite;
        hint.token = token;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint skipHint() {
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Root;
        hint.token = 0;
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
    size_t token;
    float scopeZSort;
    Composite composite;
    DynamicComposite dynamicComposite;
    DynamicCompositePass dynamicPass;
    bool maskUsesStencil;
    MaskApplyPacket[] maskPackets;
    CompositeDrawPacket compositePacket;
    RenderItem[] items;
    size_t nextSequence;
    void delegate(ref RenderCommandBuffer) dynamicPostCommands;
    bool enqueueImmediate;
}

/// Layered render graph builder that groups commands per render target scope.
final class RenderGraphBuilder {
private:
    RenderPass[] passStack;
    size_t nextToken;

    void ensureRootPass() {
        if (passStack.length == 0) {
            RenderPass root;
            root.kind = RenderPassKind.Root;
            root.token = 0;
            root.scopeZSort = 0;
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

        bool hasMasks = pass.maskPackets.length > 0 || pass.maskUsesStencil;
        if (hasMasks) {
            compositeBuffer.add(makeBeginMaskCommand(pass.maskUsesStencil));
            foreach (packet; pass.maskPackets) {
                compositeBuffer.add(makeApplyMaskCommand(packet));
            }
            compositeBuffer.add(makeBeginMaskContentCommand());
        }

        compositeBuffer.add(makeDrawCompositeQuadCommand(pass.compositePacket));

        if (hasMasks) {
            compositeBuffer.add(makeEndMaskCommand());
        }

        addItemToPass(passStack[parentIndex], pass.scopeZSort, compositeBuffer.commands.dup);

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

        if (pass.dynamicPass is null) {
            if (autoClose && pass.dynamicComposite !is null) {
                pass.dynamicComposite.dynamicScopeActive = false;
                pass.dynamicComposite.dynamicScopeToken = size_t.max;
            }
            pass.dynamicPostCommands = null;
            return;
        }
        RenderCommandBuffer buffer;
        buffer.add(makeBeginDynamicCompositeCommand(pass.dynamicPass));
        buffer.addAll(childCommands);
        buffer.add(makeEndDynamicCompositeCommand(pass.dynamicPass));

        auto finalizer = postCommands is null ? pass.dynamicPostCommands : postCommands;
        if (finalizer !is null) {
            finalizer(buffer);
        }

        addItemToPass(passStack[parentIndex], pass.scopeZSort, buffer.commands.dup);

        if (autoClose && pass.dynamicComposite !is null) {
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
            buf.formattedWrite(" #%s(kind=%s,token=%s)",
                i,
                pass.kind,
                pass.token);
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

    size_t parentPassIndexForComposite(Composite composite) const {
        if (composite is null || passStack.length == 0) return 0;
        auto ancestor = composite.parent;
        while (ancestor !is null) {
            if (auto dyn = cast(DynamicComposite)ancestor) {
                auto idx = findPassIndex(dyn.dynamicScopeTokenValue(), RenderPassKind.DynamicComposite);
                if (idx > 0) return idx;
            }
            if (auto comp = cast(Composite)ancestor) {
                auto idx = findPassIndex(comp.compositeScopeTokenValue(), RenderPassKind.Composite);
                if (idx > 0) return idx;
            }
            ancestor = ancestor.parent;
        }
        return 0;
    }

    size_t parentPassIndexForDynamic(DynamicComposite composite) const {
        if (composite is null || passStack.length == 0) return 0;
        auto ancestor = composite.parent;
        while (ancestor !is null) {
            if (auto dyn = cast(DynamicComposite)ancestor) {
                auto idx = findPassIndex(dyn.dynamicScopeTokenValue(), RenderPassKind.DynamicComposite);
                if (idx > 0) return idx;
            }
            if (auto comp = cast(Composite)ancestor) {
                auto idx = findPassIndex(comp.compositeScopeTokenValue(), RenderPassKind.Composite);
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
                index = findPassIndex(hint.token, RenderPassKind.Composite);
                enforce(index > 0, "RenderQueue: composite scope not active for enqueue. " ~ stackDebugString());
                break;
            case RenderPassKind.DynamicComposite:
                index = findPassIndex(hint.token, RenderPassKind.DynamicComposite);
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

    size_t pushComposite(Composite composite, float zSort, CompositeDrawPacket drawPacket, bool maskUsesStencil, MaskApplyPacket[] maskPackets) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.Composite;
        pass.composite = composite;
        pass.scopeZSort = zSort;
        pass.compositePacket = drawPacket;
        pass.maskUsesStencil = maskUsesStencil;
        pass.maskPackets = maskPackets.dup;
        pass.token = ++nextToken;
        pass.nextSequence = 0;
        pass.dynamicPostCommands = null;
        passStack ~= pass;
        return pass.token;
    }

    void popComposite(size_t token) {
        enforce(passStack.length > 1, "RenderQueue.popComposite called without matching push. " ~ stackDebugString());
        auto targetIndex = findPassIndex(token, RenderPassKind.Composite);
        enforce(targetIndex > 0, "RenderQueue.popComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());

        while (passStack.length - 1 > targetIndex) {
            finalizeTopPass(true);
        }

        auto pass = passStack[$ - 1];
        enforce(pass.token == token, "RenderQueue.popComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());

        finalizeCompositePass(false);
    }

    size_t pushDynamicComposite(DynamicComposite composite, DynamicCompositePass passData, float zSort) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.DynamicComposite;
        pass.dynamicComposite = composite;
        pass.dynamicPass = passData;
        pass.scopeZSort = zSort;
        pass.token = ++nextToken;
        pass.nextSequence = 0;
        pass.dynamicPostCommands = null;
        passStack ~= pass;
        return pass.token;
    }

    void popDynamicComposite(size_t token, scope void delegate(ref RenderCommandBuffer) postCommands = null) {
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
        enforce(pass.token == token, "RenderQueue.popDynamicComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());

        finalizeDynamicCompositePass(false, postCommands);
    }

    RenderCommandData[] takeCommands() {
        enforce(passStack.length == 1, "RenderGraphBuilder scopes were not balanced before takeCommands. " ~ stackDebugString());
        auto commands = collectPassCommands(passStack[0]);
        clear();
        return commands;
    }
}
