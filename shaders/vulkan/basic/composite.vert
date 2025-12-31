// Vulkan equivalent of opengl/basic/composite.vert
#version 450
layout(location = 0) in vec2 verts;
layout(location = 1) in vec2 uvs;

layout(location = 0) out vec2 texUVs;

void main() {
    gl_Position = vec4(verts, 0, 1);
    texUVs = uvs;
}
