/*
    nijilive Rendering
    Inochi2D Rendering

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core;

public import nijilive.core.shader;
public import nijilive.core.texture;
public import nijilive.core.resource;
public import nijilive.core.nodes;
public import nijilive.core.nodes.common : BlendMode;
public import nijilive.core.puppet;
public import nijilive.core.meshdata;
public import nijilive.core.param;
public import nijilive.core.automation;
public import nijilive.core.animation;
public import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
public import nijilive.core.texture_types;
public import nijilive.core.runtime_state;
public import nijilive.integration;
version(InDoesRender) {
    import nijilive.core.render.backends.opengl;
    import nijilive.core.render.backends.opengl.runtime;
}
//import std.stdio;

/**
    UDA for sub-classable parts of the spec
    eg. Nodes and Automation can be extended by
    adding new subclasses that aren't in the base spec.
*/
struct TypeId { string id; }

/**
    Different modes of interpolation between values.
*/
enum InterpolateMode {

    /**
        Round to nearest
    */
    Nearest,
    
    /**
        Linear interpolation
    */
    Linear,

    /**
        Round to nearest
    */
    Stepped,

    /**
        Cubic interpolation
    */
    Cubic,

    /**
        Interpolation using beziér splines
    */
    Bezier,

    COUNT
}
