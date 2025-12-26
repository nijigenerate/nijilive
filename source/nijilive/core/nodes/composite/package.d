/*
    nijilive Composite Node
    previously Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite;

import nijilive.core;
import nijilive.core.meshdata;
import nijilive.core.nodes;
import nijilive.core.nodes.common;
import nijilive.core.nodes.composite.dcomposite;
import nijilive.fmt;

package(nijilive) {
    void inInitComposite() {
        inRegisterNodeType!Composite;
    }
}

@TypeId("Composite")
class Composite : DynamicComposite {
public:
    bool propagateMeshGroup = true;
    alias threshold = maskAlphaThreshold;

    this(Node parent = null) {
        super(parent);
        autoResizedMesh = true;
        autoScaled = true;
    }

    this(MeshData data, uint uuid, Node parent = null) {
        super(data, uuid, parent);
        autoResizedMesh = true;
        autoScaled = true;
    }

    override bool mustPropagate() { return propagateMeshGroup; }
}
