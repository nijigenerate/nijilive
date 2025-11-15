module nijilive.math.veca_ops;

import nijilive.math : mat4;
import nijilive.math.veca : Vec2Array;
import std.algorithm : min;

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

    auto srcX = src.lane(0);
    auto srcY = src.lane(1);
    auto dstX = dest.lane(0);
    auto dstY = dest.lane(1);

    foreach (i; 0 .. len) {
        auto x = srcX[i];
        auto y = srcY[i];
        dstX[i] = m00 * x + m01 * y + m03;
        dstY[i] = m10 * x + m11 * y + m13;
    }
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

    auto srcX = src.lane(0);
    auto srcY = src.lane(1);
    auto dstX = dest.lane(0);
    auto dstY = dest.lane(1);

    foreach (i; 0 .. len) {
        auto x = srcX[i];
        auto y = srcY[i];
        dstX[i] += m00 * x + m01 * y;
        dstY[i] += m10 * x + m11 * y;
    }
}
