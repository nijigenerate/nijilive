module nijilive.core.render.backends.opengl.buffer_sync;

version (InDoesRender) {

// GL buffer fences are disabled to avoid per-draw glFenceSync spam.
// Keep stubs so call sites compile; they intentionally do nothing.
void waitForBuffer(uint /*buffer*/, string /*label*/) {}
void markBufferInUse(uint /*buffer*/) {}

} else {

void waitForBuffer(uint, string) {}
void markBufferInUse(uint) {}

}
