module nijilive.math.simd;

import core.simd;

alias FloatSimd = __vector(float[4]);
enum size_t simdWidth = FloatSimd.sizeof / float.sizeof;

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
    return *cast(FloatSimd*)(data.ptr + index);
}

void storeVec(float[] data, size_t index, FloatSimd value) @trusted {
    *cast(FloatSimd*)(data.ptr + index) = value;
}
