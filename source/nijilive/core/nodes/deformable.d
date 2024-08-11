module nijilive.core.nodes.deformable;

public import nijilive.core.nodes.defstack;
import nijilive.core;
import nijilive.core.nodes;
import nijilive.integration;
import nijilive.fmt.serialize;
import nijilive.math;
import nijilive.math.triangle;
import std.typecons: tuple, Tuple;
import nijilive.core.nodes.utils;
import std.exception;
import std.string: format;
import std.stdio;

/**
    Nodes that are meant to render something in to the nijilive scene
    Other nodes don't have to render anything and serve mostly other 
    purposes.

    The main types of Drawables are Parts and Masks
*/

private {
    vec2[] dummy = new vec2[1]; 
}
@TypeId("Deformable")
abstract class Deformable : Node {
    /**
        Constructs a new drawable surface
    */
    this(Node parent = null) {
        super(parent);
        // Create deformation stack
        this.deformStack = DeformationStack(this);
    }

    this(uint uuid, Node parent = null) {
        super(uuid, parent);
        // Create deformation stack
        this.deformStack = DeformationStack(this);
    }

    void onDeformPushed(ref Deformation deform) { }

    package(nijilive):
    final void notifyDeformPushed(ref Deformation deform) {
        onDeformPushed(deform);
    }

public:
    ref vec2[] vertices() {  return dummy; }
    void updateVertices() { };

    /**
        Deformation offset to apply
    */
    vec2[] deformation;

    /**
        Deformation stack
    */
    DeformationStack deformStack;

    /**
        Refreshes the drawable, updating its vertices
    */
    final void refresh() {
        this.updateVertices();
    }
    
    /**
        Refreshes the drawable, updating its deformation deltas
    */
    final void refreshDeform() {
        this.updateDeform();
    }

    override
    void beginUpdate() {
        deformStack.preUpdate();
        overrideTransformMatrix = null;
        super.beginUpdate();
    }

    /**
        Updates the drawable
    */
    override
    void update() {
        preProcess();
        deformStack.update();
        super.update();
        this.updateDeform();
    }

    void updateDeform() {
        // Important check since the user can change this every frame
        enforce(
            deformation.length == vertices.length, 
            "Data length mismatch for %s, deformation length=%d whereas vertices.length=%d, if you want to change the mesh you need to change its data with Part.rebuffer.".format(name, deformation.length, vertices.length)
        );
        postProcess();
    }

    override
    void preProcess() {
        if (preProcessed)
            return;
        preProcessed = true;
        foreach (preProcessFilter; preProcessFilters) {
            mat4 matrix = (overrideTransformMatrix !is null)? overrideTransformMatrix.matrix: this.transform.matrix;
            auto filterResult = preProcessFilter(this, vertices, deformation, &matrix);
            if (filterResult[0] !is null) {
                deformation = filterResult[0];
            } 
            if (filterResult[1] !is null) {
                overrideTransformMatrix = new MatrixHolder(*filterResult[1]);
            }
            if (filterResult[2]) {
                notifyChange(this);
            }

        }
    }

    override
    void postProcess() {
        if (postProcessed)
            return;
        postProcessed = true;
        foreach (postProcessFilter; postProcessFilters) {
            mat4 matrix = (overrideTransformMatrix !is null)? overrideTransformMatrix.matrix: this.transform.matrix;
            auto filterResult = postProcessFilter(this, vertices, deformation, &matrix);
            if (filterResult[0] !is null) {
                deformation = filterResult[0];
            } 
            if (filterResult[1] !is null) {
                overrideTransformMatrix = new MatrixHolder(*filterResult[1]);
            }
            if (filterResult[2]) {
                notifyChange(this);
            }
        }
    }


}