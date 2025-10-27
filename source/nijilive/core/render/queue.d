module nijilive.core.render.queue;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;

import nijilive.core.render.backends : RenderBackend, RenderGpuState;
import nijilive.core.render.commands;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;

/// Render target scopes handled by the layered queue.
enum RenderPassKind {
    Root,
    Composite,
    DynamicComposite,
}

/// Small helper used by builder delegates to accumulate commands.
struct RenderCommandBuffer {
    RenderCommandData[] commands;

    void add(RenderCommandData command) {
        commands ~= command;
    }

    void addAll(const RenderCommandData[] more) {
        foreach (command; more) {
            RenderCommandData copy = cast(RenderCommandData)command;
            commands ~= copy;
        }
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
}

final class RenderQueue {
private:
    RenderPass[] passStack;
    size_t nextPassToken;

    void ensureRootPass() {
        if (passStack.length == 0) {
            RenderPass root;
            root.kind = RenderPassKind.Root;
            root.nextSequence = 0;
            root.token = 0;
            passStack ~= root;
        }
    }

    ref RenderPass currentPass() {
        ensureRootPass();
        return passStack[$-1];
    }

    static bool renderItemCompare(ref RenderItem a, ref RenderItem b) {
        if (a.zSort == b.zSort) {
            return a.sequence < b.sequence;
        }
        return a.zSort > b.zSort; // descending
    }

    RenderCommandData[] collectPassCommands(ref RenderPass pass) {
        if (pass.items.length == 0) return [];
        pass.items.sort!renderItemCompare();

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
        enforce(passStack.length > 1, "RenderQueue: cannot finalize composite scope without active pass.");
        auto pass = passStack[$-1];
        enforce(pass.kind == RenderPassKind.Composite, "RenderQueue: top scope is not composite.");
        passStack.length -= 1;

        auto childCommands = collectPassCommands(pass);
        RenderCommandBuffer buffer;

        if (pass.maskPackets.length > 0 || pass.maskUsesStencil) {
            buffer.add(makeBeginMaskCommand(pass.maskUsesStencil));
            foreach (packet; pass.maskPackets) {
                buffer.add(makeApplyMaskCommand(packet));
            }
            buffer.add(makeBeginMaskContentCommand());
        }

        auto composite = pass.composite;
        buffer.add(makeBeginCompositeCommand());
        buffer.addAll(childCommands);
        buffer.add(makeDrawCompositeQuadCommand(makeCompositeDrawPacket(composite)));
        buffer.add(makeEndCompositeCommand());

        if (pass.maskPackets.length > 0 || pass.maskUsesStencil) {
            buffer.add(makeEndMaskCommand());
        }

        addItemToPass(currentPass(), composite.zSort(), buffer.commands);
        if (composite !is null) composite.renderScopeClosed(autoClose);
    }

    void finalizeDynamicCompositePass(bool autoClose) {
        enforce(passStack.length > 1, "RenderQueue: cannot finalize dynamic composite without active pass.");
        auto pass = passStack[$-1];
        enforce(pass.kind == RenderPassKind.DynamicComposite, "RenderQueue: top scope is not dynamic composite.");
        passStack.length -= 1;

        auto childCommands = collectPassCommands(pass);
        RenderCommandBuffer buffer;
        auto composite = pass.dynamicComposite;
        buffer.add(makeBeginDynamicCompositeCommand(composite));
        buffer.addAll(childCommands);
        buffer.add(makeEndDynamicCompositeCommand(composite));

        addItemToPass(currentPass(), composite.zSort(), buffer.commands);
        if (composite !is null) composite.renderScopeClosed(autoClose);
    }

    void finalizeTopPass() {
        enforce(passStack.length > 1, "RenderQueue: no scope available to finalize.");
        auto pass = passStack[$-1];
        final switch (pass.kind) {
            case RenderPassKind.Composite:
                finalizeCompositePass(true);
                break;
            case RenderPassKind.DynamicComposite:
                finalizeDynamicCompositePass(true);
                break;
            case RenderPassKind.Root:
                enforce(false, "RenderQueue: cannot finalize root pass.");
                break;
        }
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
        nextPassToken = 0;
        ensureRootPass();
    }

    bool empty() const {
        if (passStack.length == 0) return true;
        if (passStack.length == 1) {
            return passStack[0].items.length == 0;
        }
        // スコープが開いたままの場合は描画すべき内容があるとみなす
        return false;
    }

    void enqueueItem(float zSort, scope void delegate(ref RenderCommandBuffer) builder) {
        ensureRootPass();
        RenderCommandBuffer buffer;
        builder(buffer);
        if (buffer.commands.length == 0) return;
        addItemToPass(currentPass(), zSort, buffer.commands);
    }

    size_t findPassIndex(size_t token) const {
        foreach (index, pass; passStack) {
            if (pass.token == token) return index;
        }
        return size_t.max;
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

    size_t pushComposite(Composite composite, bool maskUsesStencil, MaskApplyPacket[] maskPackets) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.Composite;
        pass.composite = composite;
        pass.maskUsesStencil = maskUsesStencil;
        pass.maskPackets = maskPackets;
        pass.token = ++nextPassToken;
        passStack ~= pass;
        return pass.token;
    }

    void popComposite(size_t token, Composite composite) {
        size_t targetIndex = findPassIndex(token);
        enforce(targetIndex != size_t.max && targetIndex > 0,
            "RenderQueue.popComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());
        while (passStack.length - 1 > targetIndex) {
            finalizeTopPass();
        }
        auto pass = passStack[$-1];
        enforce(pass.kind == RenderPassKind.Composite && pass.composite is composite,
            "RenderQueue.popComposite scope mismatch (closing kind=" ~ pass.kind.to!string ~ ", ptr=" ~ (cast(void*)pass.composite).to!string ~ ", expected=" ~ (cast(void*)composite).to!string ~ ") " ~ stackDebugString());
        finalizeCompositePass(false);
    }

    size_t pushDynamicComposite(DynamicComposite composite) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.DynamicComposite;
        pass.dynamicComposite = composite;
        pass.token = ++nextPassToken;
        passStack ~= pass;
        return pass.token;
    }

    void popDynamicComposite(size_t token, DynamicComposite composite) {
        size_t targetIndex = findPassIndex(token);
        enforce(targetIndex != size_t.max && targetIndex > 0,
            "RenderQueue.popDynamicComposite scope mismatch (token=" ~ token.to!string ~ ") " ~ stackDebugString());
        while (passStack.length - 1 > targetIndex) {
            finalizeTopPass();
        }
        auto pass = passStack[$-1];
        enforce(pass.kind == RenderPassKind.DynamicComposite && pass.dynamicComposite is composite,
            "RenderQueue.popDynamicComposite scope mismatch (closing kind=" ~ pass.kind.to!string ~ ", ptr=" ~ (cast(void*)pass.dynamicComposite).to!string ~ ", expected=" ~ (cast(void*)composite).to!string ~ ") " ~ stackDebugString());
        finalizeDynamicCompositePass(false);
    }

    void flush(RenderBackend backend, ref RenderGpuState state) {
        if (backend is null) {
            clear();
            return;
        }

        enforce(passStack.length == 1, "RenderQueue scopes were not balanced before flush.");

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
