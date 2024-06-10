/*
    nijilive Composite Node

    Copyright © 2022, nijilive Project
    Distributed under the 2-Clause BSD License, see LICENSE file.

    Authors: Asahi Lina
*/
module nijilive.core.nodes.drivers;
import nijilive.core.nodes.common;
//import nijilive.core.nodes;
import nijilive.core;
public import nijilive.core.nodes.drivers.simplephysics;

/**
    Driver abstract node type
*/
@TypeId("Driver")
abstract class Driver : Node {
private:

    /**
        Constructs a new Driver node
    */
    this() { }

    this(uint uuid, Node parent = null) {
        super(uuid, parent);
    }

public:
    override
    void beginUpdate() {
        super.beginUpdate();
    }

    override
    void update() {
        super.update();
    }

    Parameter[] getAffectedParameters() {
        return [];
    }

    final
    bool affectsParameter(ref Parameter param) {
        foreach(ref Parameter p; getAffectedParameters()) {
            if (p.uuid == param.uuid) return true;
        } 
        return false;
    }

    abstract void updateDriver();

    abstract void reset();

    void drawDebug() {
    }
}
