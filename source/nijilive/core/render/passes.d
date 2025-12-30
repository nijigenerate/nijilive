module nijilive.core.render.passes;

/// Render target scope kinds.
enum RenderPassKind {
    Root,
    DynamicComposite,
}

/// Hint describing which render scope should receive emitted commands.
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
