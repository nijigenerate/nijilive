module nijilive.core.render.graph_builder;

import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;

import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.commands : DynamicCompositePass;
import nijilive.core.render.passes : RenderPassKind, RenderScopeHint;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite, advanceDynamicCompositeFrame;
import nijilive.core.nodes.common : MaskBinding, MaskingMode;

alias RenderCommandBuilder = void delegate(RenderCommandEmitter emitter);

private struct RenderItem {
    float zSort;
    size_t sequence;
    RenderCommandBuilder builder;
}

private struct RenderPass {
    RenderPassKind kind;
    size_t token;
    float scopeZSort;
    Composite composite;
    DynamicComposite dynamicComposite;
    DynamicCompositePass dynamicPass;
    bool maskUsesStencil;
    MaskBinding[] maskBindings;
    RenderItem[] items;
    size_t nextSequence;
    RenderCommandBuilder dynamicPostCommands;
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
        return a.zSort > b.zSort; // descending (higher zSort first)
    }

    RenderItem[] collectPassItems(ref RenderPass pass) {
        if (pass.items.length == 0) return [];
        pass.items.sort!itemLess();
        return pass.items.dup;
    }

    static void playbackItems(RenderItem[] items, RenderCommandEmitter emitter) {
        foreach (item; items) {
            if (item.builder !is null) {
                item.builder(emitter);
            }
        }
    }

    void addItemToPass(ref RenderPass pass, float zSort, RenderCommandBuilder builder) {
        if (builder is null) return;
        RenderItem item;
        item.zSort = zSort;
        item.sequence = pass.nextSequence++;
        item.builder = builder;
        pass.items ~= item;
    }

    void finalizeCompositePass(bool autoClose) {
        enforce(passStack.length > 1, "RenderQueue: cannot finalize composite scope without active pass. " ~ stackDebugString());
        auto pass = passStack[$ - 1];
        enforce(pass.kind == RenderPassKind.Composite, "RenderQueue: top scope is not composite. " ~ stackDebugString());
        size_t parentIndex = parentPassIndexForComposite(pass.composite);
        passStack.length -= 1;

        auto childItems = collectPassItems(pass);
        auto compositeNode = pass.composite;
        auto maskBindings = pass.maskBindings.dup;
        bool maskUsesStencil = pass.maskUsesStencil;
        bool hasMasks = maskBindings.length > 0 || maskUsesStencil;
        debug (UnityDLLLog) {
            import std.stdio : writefln;
            debug (UnityDLLLog) writefln("[nijilive] finalizeCompositePass masks=%s stencil=%s composite=%s", maskBindings.length, maskUsesStencil, compositeNode is null ? 0 : compositeNode.uuid);
        }

        RenderCommandBuilder builder = (RenderCommandEmitter emitter) {
            emitter.beginComposite(compositeNode);
            playbackItems(childItems, emitter);
            emitter.endComposite(compositeNode);

            if (hasMasks) {
                emitter.beginMask(maskUsesStencil);
                foreach (binding; maskBindings) {
                    if (binding.maskSrc is null) continue;
                    bool isDodge = binding.mode == MaskingMode.DodgeMask;
                    import std.stdio : writefln;
                    debug (UnityDLLLog) writefln("[nijilive] applyMask composite=%s(%s) maskSrc=%s(%s) mode=%s dodge=%s",
                        compositeNode is null ? "" : compositeNode.name,
                        compositeNode is null ? 0 : compositeNode.uuid,
                        binding.maskSrc.name, binding.maskSrc.uuid,
                        binding.mode, isDodge);
                    emitter.applyMask(binding.maskSrc, isDodge);
                }
                emitter.beginMaskContent();
            }

            emitter.drawCompositeQuad(compositeNode);

            if (hasMasks) {
                emitter.endMask();
            }
        };

        addItemToPass(passStack[parentIndex], pass.scopeZSort, builder);

        if (autoClose && compositeNode !is null) {
            compositeNode.markCompositeScopeClosed();
        }
    }

    void finalizeDynamicCompositePass(bool autoClose, RenderCommandBuilder postCommands = null) {
        enforce(passStack.length > 1, "RenderQueue: cannot finalize dynamic composite scope without active pass. " ~ stackDebugString());
        auto pass = passStack[$ - 1];
        enforce(pass.kind == RenderPassKind.DynamicComposite, "RenderQueue: top scope is not dynamic composite. " ~ stackDebugString());
        size_t parentIndex = parentPassIndexForDynamic(pass.dynamicComposite);
        passStack.length -= 1;

        auto childItems = collectPassItems(pass);

        if (pass.dynamicPass is null) {
            if (autoClose && pass.dynamicComposite !is null) {
                pass.dynamicComposite.dynamicScopeActive = false;
                pass.dynamicComposite.dynamicScopeToken = size_t.max;
            }
            pass.dynamicPostCommands = null;
            return;
        }

        auto dynamicNode = pass.dynamicComposite;
        auto passData = pass.dynamicPass;
        auto finalizer = postCommands is null ? pass.dynamicPostCommands : postCommands;
        RenderCommandBuilder builder = (RenderCommandEmitter emitter) {
            emitter.beginDynamicComposite(dynamicNode, passData);
            playbackItems(childItems, emitter);
            emitter.endDynamicComposite(dynamicNode, passData);
            if (finalizer !is null) {
                finalizer(emitter);
            }
        };

        addItemToPass(passStack[parentIndex], pass.scopeZSort, builder);

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
        advanceDynamicCompositeFrame();
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

    void enqueueItem(float zSort, RenderCommandBuilder builder) {
        enqueueItem(zSort, RenderScopeHint.root(), builder);
    }

    void enqueueItem(float zSort, RenderScopeHint hint, RenderCommandBuilder builder) {
        if (builder is null) return;
        auto ref pass = resolvePass(hint);
        addItemToPass(pass, zSort, builder);
    }

    size_t pushComposite(Composite composite, float zSort, bool maskUsesStencil, MaskBinding[] maskBindings) {
        ensureRootPass();
        RenderPass pass;
        pass.kind = RenderPassKind.Composite;
        pass.composite = composite;
        pass.scopeZSort = zSort;
        pass.maskUsesStencil = maskUsesStencil;
        pass.maskBindings = maskBindings.dup;
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

    void popDynamicComposite(size_t token, RenderCommandBuilder postCommands = null) {
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

    void playback(RenderCommandEmitter emitter) {
        enforce(passStack.length == 1, "RenderGraphBuilder scopes were not balanced before playback. " ~ stackDebugString());
        auto rootItems = collectPassItems(passStack[0]);
        clear();
        playbackItems(rootItems, emitter);
    }
}
