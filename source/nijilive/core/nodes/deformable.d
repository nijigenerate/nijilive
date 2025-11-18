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
import nijilive.core.param;
import std.exception;
import std.string: format;
import nijilive.core.render.scheduler : RenderContext;
//import std.stdio;

/**
    Nodes that are meant to render something in to the nijilive scene
    Other nodes don't have to render anything and serve mostly other 
    purposes.

    The main types of Drawables are Parts and Masks
*/

private {
    Vec2Array dummy;
}
@TypeId("Deformable")
abstract class Deformable : Node {
private:
    void initDeformableTasks() {
        requirePreProcessTask();
        requirePostTask(0);
    }

protected:
    /**
        Constructs a new drawable surface
    */
    this(Node parent = null) {
        super(parent);
        initDeformableTasks();
        // Create deformation stack
        this.deformStack = DeformationStack(this);
        this.deformation.length = 0;
    }

    this(uint uuid, Node parent = null) {
        super(uuid, parent);
        initDeformableTasks();
        // Create deformation stack
        this.deformStack = DeformationStack(this);
        this.deformation.length = 0;
    }

    void onDeformPushed(ref Deformation deform) { }

    package(nijilive):
    final void notifyDeformPushed(ref Deformation deform) {
        onDeformPushed(deform);
    }

public:
    ref Vec2Array vertices() {  return dummy; }
    void updateVertices() { };

    /**
        Deformation offset to apply
    */
    Vec2Array deformation;

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

    void rebuffer(Vec2Array vertices) {
        this.vertices = vertices;
        this.deformation.length = vertices.length;
    }

    override
    protected void runBeginTask(ref RenderContext ctx) {
        deformStack.preUpdate();
        overrideTransformMatrix = null;
        super.runBeginTask(ctx);
    }

    /**
        Updates the drawable
    */
    override
    protected void runPreProcessTask(ref RenderContext ctx) {
        super.runPreProcessTask(ctx);
        deformStack.update();
    }

    override
    protected void runDynamicTask(ref RenderContext ctx) {
        super.runDynamicTask(ctx);
    }

    override
    protected void runPostTaskImpl(size_t priority, ref RenderContext ctx) {
        super.runPostTaskImpl(priority, ctx);
        updateDeform();
    }

    void updateDeform() {
        if (deformation.length != vertices.length) {
            deformation.length = vertices.length;
            deformation[] = vec2(0, 0);
        }
    }

protected:
    void remapDeformationBindings(const size_t[] remap, const Vec2Array replacement, size_t newLength) {
        import std.stdio : writefln;
        import std.algorithm: map;
        import std.array;
        writefln("Remapping bindings for %s (remap length=%s, newLength=%s, replacement=%s)", name, remap.length, newLength, replacement.length);
        writefln("Puppet.parameters = %s", puppet.parameters.map!(a=> a.name).array);
        foreach (param; puppet.parameters) {
            if (param is null) continue;
            writefln("  Inspect parameter %s", param.name);
            foreach (binding; param.bindings) {
                if (binding.getTarget.target !is this) continue;
                auto deformBinding = cast(DeformationParameterBinding)binding;
                if (deformBinding is null) continue;
                writefln("    Adjust binding %s", deformBinding.getTarget.name);
                foreach (x; 0 .. deformBinding.values.length) {
                    foreach (y; 0 .. deformBinding.values[x].length) {
                        auto offsets = deformBinding.values[x][y].vertexOffsets;
                        if (remap.length == offsets.length && remap.length > 0) {
                            Vec2Array reordered;
                            reordered.length = remap.length;
                            foreach (oldIdx, newIdx; remap) {
                                reordered[newIdx] = offsets[oldIdx];
                            }
                            deformBinding.values[x][y].vertexOffsets = reordered;
                            writefln("      Reordered keypoint (%s, %s)", x, y);
                        } else if (replacement.length == newLength && newLength > 0) {
                            deformBinding.values[x][y].vertexOffsets = replacement.dup;
                            deformBinding.isSet_[x][y] = true;
                            writefln("      Replaced keypoint (%s, %s) with new deformation.", x, y);
                        } else {
                            offsets.length = newLength;
                            offsets[] = vec2(0, 0);
                            deformBinding.values[x][y].vertexOffsets = offsets;
                            deformBinding.isSet_[x][y] = false;
                            writefln("      Reset keypoint (%s, %s) due to mismatch (%s -> %s)", x, y, offsets.length, newLength);
                        }
                    }
                }
            }
        }
    }

    override
    void preProcess() {
        if (preProcessed)
            return;
        preProcessed = true;
        foreach (preProcessFilter; preProcessFilters) {
            mat4 matrix = (overrideTransformMatrix !is null)? overrideTransformMatrix.matrix: this.transform.matrix;
            auto filterResult = preProcessFilter[1](this, vertices, deformation, &matrix);
            if (!filterResult[0].empty) {
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
    void postProcess(int id = 0) {
        if (postProcessed >= id)
            return;
        postProcessed = id;
        foreach (postProcessFilter; postProcessFilters) {
            if (postProcessFilter[0] != id) continue;
            mat4 matrix = (overrideTransformMatrix !is null)? overrideTransformMatrix.matrix: this.transform.matrix;
            auto filterResult = postProcessFilter[1](this, vertices, deformation, &matrix);
            if (!filterResult[0].empty) {
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
