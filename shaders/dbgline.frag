/*
    Copyright © 2020, nijilive Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
#version 330
layout(location = 0) out vec4 outColor;

uniform vec4 color;

void main() {
    outColor = color;
}