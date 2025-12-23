module nijilive.core.nodes.deformer.base;

import nijilive.core.nodes;
import nijilive.core.nodes.filter;
import nijilive.math;
import std.typecons : Tuple;

/**
    Base interface for deformation-only node filters.
    Deformer implementations are expected to provide deformation
    behaviour without introducing additional drawable features.
*/
interface Deformer : NodeFilter {
    Tuple!(Vec2Array, mat4*, bool) deformChildren(Node target, Vec2Array origVertices, Vec2Array origDeformation, mat4* origTransform);
    void clearCache();
}
