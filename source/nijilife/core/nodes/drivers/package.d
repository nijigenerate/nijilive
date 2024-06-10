/*
    nijilife Composite Node

    Copyright © 2022, nijilife Project
    Distributed under the 2-Clause BSD License, see LICENSE file.

    Authors: Asahi Lina
*/
module nijilife.core.nodes.drivers;
import nijilife.core.nodes.common;
//import nijilife.core.nodes;
import nijilife.core;
public import nijilife.core.nodes.drivers.simplephysics;

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
