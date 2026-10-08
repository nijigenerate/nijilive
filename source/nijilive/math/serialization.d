module nijilive.math.serialization;
import nijilive.math : Vec2Array;
import nijilive.fmt.serialize;
import inmath.linalg;
import inmath.util;

/**
    Serializes any size of vector
*/
void serialize(V, S)(V value, ref S serializer) if(isVector!V) {
    auto state = serializer.listBegin();
    static foreach(i; 0..V.dimension) {
        serializer.elemBegin;
        serializer.serializeValue(value.vector[i]);
    }
    serializer.listEnd(state);
}

/**
    Serializes any size of matrix
*/
void serialize(T, S)(T matr, ref S serializer) if(isMatrix!T) {
    auto state = serializer.listBegin();
    static foreach(y; 0..T.rows) {
        static foreach(x; 0..T.cols) {
            serializer.elemBegin;
            serializer.serializeValue(matr.matrix[x][y]);
        }
    }
    serializer.listEnd(state);
}

SerdeException deserialize(V)(ref V value, Fghj data) if (isVector!V) {
    import std.exception : enforce;
    if (data == Fghj.init || data.kind == Fghj.Kind.null_) return null;
    enforce(data.kind == Fghj.Kind.array, "Expected a numeric vector array");
    int i = 0;
    foreach(val; data.byElement) {
        
        // Some exporters export too many values
        if (i >= value.dimension) break;
        auto error = inDeserializeNumber(val, value.vector[i]);
        if (error !is null) return error;
        i++;
    }
    return null;
}

bool isEmpty(Fghj value) {
    return value == Fghj.init;
}

/** Recover only missing components from nearby finite mesh samples. */
size_t inRecoverDeformationOffsets(const Vec2Array vertices, ref Vec2Array offsets, const(ubyte)[] missing) {
    import std.math : abs, isFinite, sqrt;
    import std.algorithm : min, max, sort;
    struct Sample { size_t index; double distance; }
    size_t recovered;
    foreach (i; 0 .. min(vertices.length, min(offsets.length, missing.length))) {
        foreach (component; 0 .. 2) {
            if (!(missing[i] & (1 << component))) continue;
            Sample[] samples;
            foreach (j; 0 .. min(vertices.length, offsets.length)) {
                if (j < missing.length && (missing[j] & (1 << component))) continue;
                if (!isFinite(offsets[j].toVector().vector[component])) continue;
                auto delta = vertices[j].toVector() - vertices[i].toVector();
                double distance = cast(double)delta.x * delta.x + cast(double)delta.y * delta.y;
                if (isFinite(distance)) samples ~= Sample(j, distance);
            }
            if (!samples.length) continue;
            samples.sort!((a, b) => a.distance < b.distance || (a.distance == b.distance && a.index < b.index));
            double value = offsets[samples[0].index].toVector().vector[component];
            if (samples[0].distance > 1e-8) {
                auto count = min(samples.length, 16);
                double radius = sqrt(samples[count - 1].distance);
                double a00 = 0, a01 = 0, a02 = 0, a11 = 0, a12 = 0, a22 = 0;
                double b0 = 0, b1 = 0, b2 = 0;
                foreach (sample; samples[0 .. count]) {
                    auto delta = vertices[sample.index].toVector() - vertices[i].toVector();
                    double x = delta.x / radius, y = delta.y / radius;
                    double weight = 1 / max(sample.distance, 1e-8);
                    double v = offsets[sample.index].toVector().vector[component];
                    a00 += weight; a01 += weight * x; a02 += weight * y;
                    a11 += weight * x * x; a12 += weight * x * y; a22 += weight * y * y;
                    b0 += weight * v; b1 += weight * x * v; b2 += weight * y * v;
                }
                auto c0 = a11 * a22 - a12 * a12;
                auto c1 = a02 * a12 - a01 * a22;
                auto c2 = a01 * a12 - a02 * a11;
                auto determinant = a00 * c0 + a01 * c1 + a02 * c2;
                value = abs(determinant) > 1e-10 * a00 * a11 * a22 ?
                    (c0 * b0 + c1 * b1 + c2 * b2) / determinant : b0 / a00;
            }
            if (isFinite(value)) {
                auto offset = offsets[i].toVector();
                offset.vector[component] = cast(float)value;
                if (!isFinite(offset.vector[component])) continue;
                offsets[i] = offset;
                recovered++;
            }
        }
    }
    return recovered;
}
