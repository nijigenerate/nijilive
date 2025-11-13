module nijilive.core.nodes.defstack;
import nijilive.core;
import nijilive.math;
import nijilive;
import std.exception : enforce;

/**
    A deformation
*/
struct Deformation {

    /**
        Deformed values
    */
    Vec2Array vertexOffsets;

    void update(Vec2Array points) {
        vertexOffsets = points.dup;
    }

    this(this) pure @safe nothrow {
        vertexOffsets = vertexOffsets.dup;
    }

    Deformation opUnary(string op : "-")() @safe pure nothrow {
        Deformation new_;

        new_.vertexOffsets = vertexOffsets.dup;
        new_.vertexOffsets *= -1;

        return new_;
    }

    Deformation opBinary(string op : "*", T)(T other) @safe pure nothrow {
        static if (is(T == Deformation)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets *= other.vertexOffsets;

            return new_;
        } else static if (is(T == vec2)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets *= other;

            return new_;
        } else {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets *= other;

            return new_;
        }
    }

    Deformation opBinaryRight(string op : "*", T)(T other) @safe pure nothrow {
        static if (is(T == Deformation)) {
            Deformation new_;

            new_.vertexOffsets = other.vertexOffsets.dup;
            new_.vertexOffsets *= vertexOffsets;

            return new_;
        } else static if (is(T == vec2)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets *= other;

            return new_;
        } else {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets *= other;

            return new_;
        }
    }

    Deformation opBinary(string op : "+", T)(T other) @safe pure nothrow {
        static if (is(T == Deformation)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets += other.vertexOffsets;

            return new_;
        } else static if (is(T == vec2)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets += other;

            return new_;
        } else {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets += other;

            return new_;
        }
    }

    Deformation opBinary(string op : "-", T)(T other) @safe pure nothrow {
        static if (is(T == Deformation)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets -= other.vertexOffsets;

            return new_;
        } else static if (is(T == vec2)) {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets -= other;

            return new_;
        } else {
            Deformation new_;

            new_.vertexOffsets = vertexOffsets.dup;
            new_.vertexOffsets -= other;

            return new_;
        }
    }

    void serialize(S)(ref S serializer) {
        import nijilive.math.serialization : serialize;
        auto state = serializer.listBegin();
            foreach(offset; vertexOffsets) {
                serializer.elemBegin;
                offset.serialize(serializer);
            }
        serializer.listEnd(state);
    }

    SerdeException deserializeFromFghj(Fghj data) {
        import nijilive.math.serialization : deserialize;
        foreach(elem; data.byElement()) {
            vec2 offset;
            offset.deserialize(elem);

            vertexOffsets ~= offset;
        }

        return null;
    }
}

/**
    A stack of local deformations to apply to the mesh
*/
struct DeformationStack {
private:
    Deformable parent;

public:
    this(Deformable parent) {
        this.parent = parent;
    }

    /**
        Push deformation on to stack
    */
    void push(ref Deformation deformation) {
        if (this.parent.deformation.length != deformation.vertexOffsets.length) return;
        this.parent.deformation += deformation.vertexOffsets;
        this.parent.notifyDeformPushed(deformation);
    }
    
    void preUpdate() {
        this.parent.deformation[] = vec2(0);
    }

    void update() {
        parent.refreshDeform();
    }
}
