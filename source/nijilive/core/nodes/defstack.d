module nijilive.core.nodes.defstack;
import nijilive.core;
import nijilive.math;
import nijilive;
import std.exception : enforce;
import std.algorithm.mutation : move;

/**
    A deformation
*/
struct Deformation {

    /**
        Deformed values
    */
    Vec2Array vertexOffsets;

    void update(Vec2Array points) {
        auto copied = points.dup;
        move(copied, vertexOffsets);
    }

    this(this) pure @safe nothrow {
        // veca assignment copies into existing storage; transfer the independent backing instead.
        auto copied = vertexOffsets.dup;
        move(copied, vertexOffsets);
    }

    ref Deformation opAssign(const Deformation other) return @safe pure nothrow {
        auto copied = other.vertexOffsets.dup;
        move(copied, vertexOffsets);
        return this;
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
        vertexOffsets.length = 0;
        size_t vertex;
        foreach(elem; data.byElement()) {
            vec2 offset;
            try {
                import std.range : walkLength;
                enforce(elem.kind == Fghj.Kind.array && elem.byElement.walkLength >= 2,
                    "Not enough components in deformation vector");
                auto error = offset.deserialize(elem);
                enforce(error is null, error is null ? "" : error.msg);
            } catch (Exception error) {
                import std.format : format;
                throw new Exception(format("Deformation vertex %s: %s", vertex, error.msg), error);
            }

            vertexOffsets ~= offset;
            vertex++;
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
