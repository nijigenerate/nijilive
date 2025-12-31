// Vulkan equivalent of opengl/mask.vert
#version 450
layout(set = 0, binding = 0) uniform Globals {
    mat4 mvp;
    vec2 offset;
} globals;

layout(location = 0) in float vertX;
layout(location = 1) in float vertY;
layout(location = 2) in float deformX;
layout(location = 3) in float deformY;

void main() {
    vec2 verts = vec2(vertX, vertY);
    vec2 deform = vec2(deformX, deformY);
    gl_Position = globals.mvp * vec4(verts.x - globals.offset.x + deform.x, verts.y - globals.offset.y + deform.y, 0, 1);
}
