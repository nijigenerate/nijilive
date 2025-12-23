module nijilive.math.veca_ops;

import std.algorithm : min;
import nijilive.math : mat4;
import nijilive.math.veca : Vec2Array;
import nijilive.math.simd : FloatSimd, SimdRepr, simdWidth, splatSimd, loadVec, storeVec;

private void simdLinearCombination(bool accumulate)(
    float[] dst,
    const float[] lhs,
    const float[] rhs,
    float lhsCoeff,
    float rhsCoeff,
    float bias) {
    assert(dst.length == lhs.length && lhs.length == rhs.length);
    auto len = dst.length;
    auto lhsVec = splatSimd(lhsCoeff);
    auto rhsVec = splatSimd(rhsCoeff);
    auto biasVec = splatSimd(bias);
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto l = loadVec(lhs, i);
        auto r = loadVec(rhs, i);
        auto value = lhsVec * l + rhsVec * r + biasVec;
        static if (accumulate) {
            value += loadVec(dst, i);
        }
        storeVec(dst, i, value);
    }
    for (; i < len; ++i) {
        auto scalar = lhsCoeff * lhs[i] + rhsCoeff * rhs[i] + bias;
        static if (accumulate)
            dst[i] += scalar;
        else
            dst[i] = scalar;
    }
}

private void simdBlendAxes(
    float[] dst,
    const float[] base,
    const float[] scaleA,
    const float[] dirA,
    const float[] scaleB,
    const float[] dirB) {
    assert(dst.length == base.length);
    assert(base.length == scaleA.length);
    assert(scaleA.length == dirA.length);
    assert(scaleB.length == dirB.length);
    size_t len = dst.length;
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto baseVec = loadVec(base, i);
        auto termA = loadVec(scaleA, i) * loadVec(dirA, i);
        auto termB = loadVec(scaleB, i) * loadVec(dirB, i);
        storeVec(dst, i, baseVec + termA + termB);
    }
    for (; i < len; ++i) {
        dst[i] = base[i] + scaleA[i] * dirA[i] + scaleB[i] * dirB[i];
    }
}

private void projectAxesSimd(
    float[] outAxisA,
    float[] outAxisB,
    const float[] centerX,
    const float[] centerY,
    const float[] referenceX,
    const float[] referenceY,
    const float[] axisAX,
    const float[] axisAY,
    const float[] axisBX,
    const float[] axisBY) {
    assert(outAxisA.length == outAxisB.length);
    auto len = outAxisA.length;
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto cx = loadVec(centerX, i);
        auto cy = loadVec(centerY, i);
        auto rx = loadVec(referenceX, i);
        auto ry = loadVec(referenceY, i);
        auto diffX = cx - rx;
        auto diffY = cy - ry;
        auto axisARes = diffX * loadVec(axisAX, i) + diffY * loadVec(axisAY, i);
        auto axisBRes = diffX * loadVec(axisBX, i) + diffY * loadVec(axisBY, i);
        storeVec(outAxisA, i, axisARes);
        storeVec(outAxisB, i, axisBRes);
    }
    for (; i < len; ++i) {
        auto diffX = centerX[i] - referenceX[i];
        auto diffY = centerY[i] - referenceY[i];
        outAxisA[i] = diffX * axisAX[i] + diffY * axisAY[i];
        outAxisB[i] = diffX * axisBX[i] + diffY * axisBY[i];
    }
}

private void rotateAxesSimd(
    float[] dstX,
    float[] dstY,
    const float[] srcX,
    const float[] srcY) {
    assert(dstX.length == dstY.length);
    assert(srcX.length == srcY.length);
    auto len = dstX.length;
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto sx = loadVec(srcX, i);
        auto sy = loadVec(srcY, i);
        storeVec(dstX, i, -sy);
        storeVec(dstY, i, sx);
    }
    for (; i < len; ++i) {
        dstX[i] = -srcY[i];
        dstY[i] = srcX[i];
    }
}

package(nijilive) void projectVec2OntoAxes(
    const Vec2Array center,
    const Vec2Array reference,
    const Vec2Array axisA,
    const Vec2Array axisB,
    float[] outAxisA,
    float[] outAxisB) {
    auto len = center.length;
    if (len == 0) return;
    assert(reference.length == len);
    assert(axisA.length == len);
    assert(axisB.length == len);
    assert(outAxisA.length >= len);
    assert(outAxisB.length >= len);
    auto centerX = center.lane(0)[0 .. len];
    auto centerY = center.lane(1)[0 .. len];
    auto refX = reference.lane(0)[0 .. len];
    auto refY = reference.lane(1)[0 .. len];
    auto axisAX = axisA.lane(0)[0 .. len];
    auto axisAY = axisA.lane(1)[0 .. len];
    auto axisBX = axisB.lane(0)[0 .. len];
    auto axisBY = axisB.lane(1)[0 .. len];
    projectAxesSimd(
        outAxisA[0 .. len],
        outAxisB[0 .. len],
        centerX,
        centerY,
        refX,
        refY,
        axisAX,
        axisAY,
        axisBX,
        axisBY);
}

package(nijilive) void composeVec2FromAxes(
    ref Vec2Array dest,
    const Vec2Array base,
    const float[] axisA,
    const Vec2Array dirA,
    const float[] axisB,
    const Vec2Array dirB) {
    auto len = base.length;
    if (len == 0) {
        dest.length = 0;
        return;
    }
    dest.length = len;
    assert(dirA.length == len);
    assert(dirB.length == len);
    assert(axisA.length >= len);
    assert(axisB.length >= len);
    auto dstX = dest.lane(0)[0 .. len];
    auto dstY = dest.lane(1)[0 .. len];
    auto baseX = base.lane(0)[0 .. len];
    auto baseY = base.lane(1)[0 .. len];
    auto dirAX = dirA.lane(0)[0 .. len];
    auto dirAY = dirA.lane(1)[0 .. len];
    auto dirBX = dirB.lane(0)[0 .. len];
    auto dirBY = dirB.lane(1)[0 .. len];
    simdBlendAxes(dstX, baseX, axisA[0 .. len], dirAX, axisB[0 .. len], dirBX);
    simdBlendAxes(dstY, baseY, axisA[0 .. len], dirAY, axisB[0 .. len], dirBY);
}

package(nijilive) void rotateVec2TangentsToNormals(
    ref Vec2Array normals,
    const Vec2Array tangents) {
    auto len = tangents.length;
    normals.length = len;
    if (len == 0) return;
    auto dstX = normals.lane(0)[0 .. len];
    auto dstY = normals.lane(1)[0 .. len];
    auto srcX = tangents.lane(0)[0 .. len];
    auto srcY = tangents.lane(1)[0 .. len];
    rotateAxesSimd(dstX, dstY, srcX, srcY);
}

/// Writes `matrix * src` into `dest`, applying the translational part.
void transformAssign(ref Vec2Array dest, const Vec2Array src, const mat4 matrix) {
    dest.length = src.length;
    auto len = src.length;
    if (len == 0) return;

    const float m00 = matrix[0][0];
    const float m01 = matrix[0][1];
    const float m03 = matrix[0][3];
    const float m10 = matrix[1][0];
    const float m11 = matrix[1][1];
    const float m13 = matrix[1][3];

    auto srcX = src.lane(0)[0 .. len];
    auto srcY = src.lane(1)[0 .. len];
    auto dstX = dest.lane(0)[0 .. len];
    auto dstY = dest.lane(1)[0 .. len];

    simdLinearCombination!false(dstX, srcX, srcY, m00, m01, m03);
    simdLinearCombination!false(dstY, srcX, srcY, m10, m11, m13);
}

/// Adds the linear part of `matrix * src` into `dest` (no translation).
void transformAdd(ref Vec2Array dest, const Vec2Array src, const mat4 matrix, size_t count = size_t.max) {
    if (dest.length == 0 || src.length == 0) return;
    auto len = min(count, min(dest.length, src.length));
    if (len == 0) return;

    const float m00 = matrix[0][0];
    const float m01 = matrix[0][1];
    const float m10 = matrix[1][0];
    const float m11 = matrix[1][1];

    auto srcX = src.lane(0)[0 .. len];
    auto srcY = src.lane(1)[0 .. len];
    auto dstX = dest.lane(0)[0 .. len];
    auto dstY = dest.lane(1)[0 .. len];

    simdLinearCombination!true(dstX, srcX, srcY, m00, m01, 0);
    simdLinearCombination!true(dstY, srcX, srcY, m10, m11, 0);
}
