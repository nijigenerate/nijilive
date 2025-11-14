module nijilive.core.render.backends.opengl.buffer_sync;

version (InDoesRender) {

import bindbc.opengl;
import core.time : hnsecs;
import std.algorithm.mutation : remove;

import nijilive.core.render.profiler : profileScope;

private __gshared GLsync[GLuint] bufferFences;

void waitForBuffer(GLuint buffer, string label) {
    if (buffer == 0 || label.length == 0) return;
    auto fencePtr = buffer in bufferFences;
    if (fencePtr is null || *fencePtr is null) return;
    auto waitScope = profileScope(label);
    const long timeoutNs = 1_000_000; // 1 ms
    while (true) {
        auto result = glClientWaitSync(*fencePtr, GL_SYNC_FLUSH_COMMANDS_BIT, timeoutNs);
        if (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) {
            break;
        }
        if (result == GL_WAIT_FAILED) {
            break;
        }
    }
    glDeleteSync(*fencePtr);
    bufferFences.remove(buffer);
}

void markBufferInUse(GLuint buffer) {
    if (buffer == 0) return;
    auto newFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    auto fencePtr = buffer in bufferFences;
    if (fencePtr !is null && *fencePtr !is null) {
        glDeleteSync(*fencePtr);
    }
    bufferFences[buffer] = newFence;
}

} else {

void waitForBuffer(uint, string) {}
void markBufferInUse(uint) {}

}
