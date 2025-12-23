/*
    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
#version 330
uniform mat4 mvp;
uniform vec2 offset;

layout(location = 0) in float vertX;
layout(location = 1) in float vertY;
layout(location = 2) in float uvX;
layout(location = 3) in float uvY;
layout(location = 4) in float deformX;
layout(location = 5) in float deformY;

out vec2 texUVs;

void main() {
    vec2 verts = vec2(vertX, vertY);
    vec2 deform = vec2(deformX, deformY);
    vec2 uvs = vec2(uvX, uvY);
    gl_Position = mvp * vec4(verts.x - offset.x + deform.x, verts.y - offset.y + deform.y, 0, 1);
    texUVs = uvs;
}
