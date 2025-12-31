// Vulkan equivalent of opengl/basic/basic.vert
#version 450
layout(set = 0, binding = 0) uniform Globals {
    mat4 mvp;
    vec2 offset;
} globals;

layout(location = 0) in float vertX;
layout(location = 1) in float vertY;
layout(location = 2) in float uvX;
layout(location = 3) in float uvY;
layout(location = 4) in float deformX;
layout(location = 5) in float deformY;

layout(location = 0) out vec2 texUVs;

void main() {
    vec2 verts = vec2(vertX, vertY);
    vec2 deform = vec2(deformX, deformY);
    vec2 uvs = vec2(uvX, uvY);
    gl_Position = globals.mvp * vec4(verts.x - globals.offset.x + deform.x, verts.y - globals.offset.y + deform.y, 0, 1);
    texUVs = uvs;
}
