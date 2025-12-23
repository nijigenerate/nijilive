/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.integration;

version(InRenderless) {
    struct TextureBlob {
        ubyte tag;
        ubyte[] data;
    }

    TextureBlob[] inCurrentPuppetTextureSlots;

    string inPartMaskShader = import("opengl/basic/basic-mask.frag");
    string inPartFragmentShader = import("opengl/basic/basic.frag");
    string inPartVertexShader = import("opengl/basic/basic.vert");

    string inCompositeMaskShader = import("opengl/basic/composite-mask.frag");
    string inCompositeFragmentShader = import("opengl/basic/composite.frag");
    string inCompositeVertexShader = import("opengl/basic/composite.vert");

    string inMaskFragmentShader = import("opengl/mask.frag");
    string inMaskVertexShader = import("opengl/mask.vert");


} else {

}

