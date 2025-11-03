# Rendering Pipeline Refactor Tasks

- [x] Align delegated dynamic composite processing with `doc/new_rendering.md` §5 by queueing its per-frame tasks through `TaskQueue` instead of `runManualTick`.
- [x] Ensure `Composite` follows the single traversal scheduling outlined in `doc/new_rendering.md` §4–5, including removing manual tick fallbacks and registering delegated work with the scheduler.
