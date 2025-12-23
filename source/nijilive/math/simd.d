module nijilive.math.simd;

import core.simd;

alias FloatSimd = __vector(float[4]);
enum size_t simdWidth = FloatSimd.sizeof / float.sizeof;
enum size_t floatSimdAlignment = FloatSimd.alignof ? FloatSimd.alignof : FloatSimd.sizeof;
enum size_t floatSimdMask = floatSimdAlignment - 1;

union SimdRepr {
    FloatSimd vec;
    float[simdWidth] scalars;
}

FloatSimd splatSimd(float value) @trusted {
    SimdRepr repr;
    repr.scalars[] = value;
    return repr.vec;
}

FloatSimd loadVec(const float[] data, size_t index) @trusted {
    auto ptr = data.ptr + index;
    if (((cast(size_t)ptr) & floatSimdMask) == 0) {
        return *cast(FloatSimd*)ptr;
    }
    SimdRepr repr;
    repr.scalars[] = data[index .. index + simdWidth];
    return repr.vec;
}

void storeVec(float[] data, size_t index, FloatSimd value) @trusted {
    auto ptr = data.ptr + index;
    if (((cast(size_t)ptr) & floatSimdMask) == 0) {
        *cast(FloatSimd*)ptr = value;
        return;
    }
    SimdRepr repr;
    repr.vec = value;
    data[index .. index + simdWidth] = repr.scalars[];
}
