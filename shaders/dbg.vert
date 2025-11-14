/*
    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
#version 330
uniform mat4 mvp;
layout(location = 0) in float vertX;
layout(location = 1) in float vertY;
layout(location = 2) in float vertZ;

out vec2 texUVs;

void main() {
    vec3 verts = vec3(vertX, vertY, vertZ);
    gl_Position = mvp * vec4(verts, 1.0);
}
