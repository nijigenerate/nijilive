module nijilive.core.render.backends.opengl.soa_upload;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.math : veca;
import std.traits : Unqual;
import nijilive.core.render.profiler : profileScope, RenderProfileScope;
import nijilive.core.render.backends.opengl.buffer_sync : waitForBuffer;

private template VecInfo(Vec) {
    static if (is(Unqual!Vec == veca!(float, N), size_t N)) {
        enum bool isValid = true;
        enum size_t laneCount = N;
    } else {
        enum bool isValid = false;
        enum size_t laneCount = 0;
    }
}

/// Uploads SoA vector data without converting to AoS on the CPU.
void glUploadFloatVecArray(Vec)(GLuint buffer, auto ref Vec data, GLenum usage, string profileLabel = null)
if (VecInfo!Vec.isValid) {
    if (buffer == 0 || data.length == 0) return;
    if (profileLabel.length)
        waitForBuffer(buffer, profileLabel ~ ".Wait");
    RenderProfileScope totalScope;
    if (profileLabel.length)
        totalScope = profileScope(profileLabel ~ ".Total");
    enum laneCount = VecInfo!Vec.laneCount;
    auto laneBytes = cast(size_t)data.length * float.sizeof;
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    const size_t totalBytes = laneBytes * laneCount;
    auto raw = data.rawStorage();
    debug {
        assert(raw.length == laneCount * data.length);
    }
    if (raw.length == 0) return;
    {
        RenderProfileScope orphanScope;
        if (profileLabel.length)
            orphanScope = profileScope(profileLabel ~ ".Orphan");
        glBufferData(GL_ARRAY_BUFFER, totalBytes, null, usage);
    }
    {
        RenderProfileScope copyScope;
        if (profileLabel.length)
            copyScope = profileScope(profileLabel ~ ".Copy");
        glBufferSubData(GL_ARRAY_BUFFER, 0, totalBytes, raw.ptr);
    }
}

} else {

void glUploadFloatVecArray(Vec)(uint, auto ref Vec, uint) {}

}
