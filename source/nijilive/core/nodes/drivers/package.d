/*
    nijilive Composite Node
    previously Inochi2D Composite Node

    Copyright © 2022, Inochi2D Project
    Copyright © 2024, nijigenerate Project
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
protected:

    /**
        Constructs a new Driver node
    */
    this() { }

    this(uint uuid, Node parent = null) {
        super(uuid, parent);
    }

public:
    override
    protected void runBeginTask() {
        super.runBeginTask();
    }

    override
    void runManualTick() {
        runPreProcessTask();
        runDynamicTask();
        if (!enabled) return;
        foreach(child; children) {
            child.runManualTick();
        }
    }

    override
    protected void runDynamicTask() {
        if (puppet !is null && puppet.renderParameters && puppet.enableDrivers) {
            updateDriver();
        }
        super.runDynamicTask();
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
