module nijilive.core.nodes.deformer.curve;

import nijilive.math;
import nijilive.math.simd : FloatSimd, SimdRepr, simdWidth, splatSimd, loadVec, storeVec;

private {
float binomial(long n, long k) {
    if (k > n) return 0.0;
    if (k == 0 || k == n) return 1.0;

    k = (k > n - k) ? n - k : k;

    float result = 1.0;
    for (int i = 0; i < k; ++i) {
        result *= (n - i) / float(i + 1);
    }
    return result;
}    
}

interface Curve {
    vec2 point(float t);
    float closestPoint(vec2 point, int nSamples = 100);
    ref Vec2Array controlPoints();
    void controlPoints(ref Vec2Array points);
    vec2 derivative(float t);
    void evaluatePoints(const float[] samples, ref Vec2Array dst);
    void evaluateDerivatives(const float[] samples, ref Vec2Array dst);
}

class BezierCurve : Curve{
    Vec2Array _controlPoints;
    Vec2Array derivatives; // Precomputed Bezier curve derivatives
    vec2[float] pointCache;
public:
    this(Vec2Array controlPoints) {
        this.controlPoints = controlPoints.dup;
        auto derivativeLength = controlPoints.length > 0 ? controlPoints.length - 1 : 0;
        this.derivatives = Vec2Array(derivativeLength);
        calculateDerivatives();
    }

    override
    ref Vec2Array controlPoints() { return _controlPoints; }
    
    override
    void controlPoints(ref Vec2Array points) { this._controlPoints = points; }

    // Compute the point on the Bezier curve
    override
    vec2 point(float t) {
        if (t in pointCache)
            return pointCache[t];
        Vec2Array tmp;
        float[1] sampleBuf;
        sampleBuf[0] = t;
        evaluatePoints(sampleBuf[], tmp);
        auto result = tmp[0].toVector();
        pointCache[t] = result;
        return result;
    }

    // Compute the derivatives of the Bezier curve
    void calculateDerivatives() {
        long n = controlPoints.length - 1;
        for (int i = 0; i < n; ++i) {
            derivatives[i] = (controlPoints[i + 1] - controlPoints[i]) * n;
        }
    }

    // Compute the point of the derivative of the Bezier curve
    override
    vec2 derivative(float t) {
        Vec2Array tmp;
        float[1] sampleBuf;
        sampleBuf[0] = t;
        evaluateDerivatives(sampleBuf[], tmp);
        return tmp[0].toVector();
    }

    override
    void evaluatePoints(const float[] samples, ref Vec2Array dst) {
        dst.length = samples.length;
        if (samples.length == 0 || _controlPoints.length == 0) {
            return;
        }
        long n = _controlPoints.length - 1;
        auto dstX = dst.lane(0);
        auto dstY = dst.lane(1);
        auto cpX = _controlPoints.lane(0);
        auto cpY = _controlPoints.lane(1);
        FloatSimd[] tPowers;
        FloatSimd[] oneMinusTPowers;
        tPowers.length = cast(size_t)(n + 1);
        oneMinusTPowers.length = cast(size_t)(n + 1);
        float[] scalarTPowers;
        float[] scalarOneMinus;
        scalarTPowers.length = cast(size_t)(n + 1);
        scalarOneMinus.length = cast(size_t)(n + 1);

        size_t idx = 0;
        for (; idx + simdWidth <= samples.length; idx += simdWidth) {
            auto tVec = loadVec(samples, idx);
            auto oneMinusT = splatSimd(1.0f) - tVec;
            tPowers[0] = splatSimd(1.0f);
            oneMinusTPowers[0] = splatSimd(1.0f);
            foreach (i; 1 .. n + 1) {
                tPowers[i] = tPowers[i - 1] * tVec;
                oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
            }

            auto resX = splatSimd(0);
            auto resY = splatSimd(0);
            foreach (i; 0 .. n + 1) {
                auto coeff = splatSimd(cast(float)binomial(n, i))
                    * oneMinusTPowers[n - i]
                    * tPowers[i];
                auto px = splatSimd(cpX[i]);
                auto py = splatSimd(cpY[i]);
                resX += coeff * px;
                resY += coeff * py;
            }
            storeVec(dstX, idx, resX);
            storeVec(dstY, idx, resY);
        }

        for (; idx < samples.length; ++idx) {
            float t = samples[idx];
            float resXScalar = 0;
            float resYScalar = 0;
            float oneMinusT = 1 - t;
            scalarTPowers[0] = 1;
            scalarOneMinus[0] = 1;
            foreach (i; 1 .. n + 1) {
                scalarTPowers[i] = scalarTPowers[i - 1] * t;
                scalarOneMinus[i] = scalarOneMinus[i - 1] * oneMinusT;
            }
            foreach (i; 0 .. n + 1) {
                float binCoeff = cast(float)binomial(n, i);
                float coeff = binCoeff * scalarOneMinus[n - i] * scalarTPowers[i];
                resXScalar += coeff * cpX[i];
                resYScalar += coeff * cpY[i];
            }
            dstX[idx] = resXScalar;
            dstY[idx] = resYScalar;
        }
    }

    override
    void evaluateDerivatives(const float[] samples, ref Vec2Array dst) {
        dst.length = samples.length;
        size_t derivCount = derivatives.length;
        if (samples.length == 0 || derivCount == 0) {
            return;
        }
        long n = cast(long)derivCount;
        auto dstX = dst.lane(0);
        auto dstY = dst.lane(1);
        auto derivX = derivatives.lane(0);
        auto derivY = derivatives.lane(1);
        FloatSimd[] tPowers;
        FloatSimd[] oneMinusTPowers;
        tPowers.length = cast(size_t)(n);
        oneMinusTPowers.length = cast(size_t)(n);
        float[] scalarTPowers;
        float[] scalarOneMinus;
        scalarTPowers.length = cast(size_t)(n);
        scalarOneMinus.length = cast(size_t)(n);

        size_t idx = 0;
        for (; idx + simdWidth <= samples.length; idx += simdWidth) {
            auto tVec = loadVec(samples, idx);
            auto oneMinusT = splatSimd(1.0f) - tVec;
            if (n > 0) {
                tPowers[0] = splatSimd(1.0f);
                oneMinusTPowers[0] = splatSimd(1.0f);
            }
            foreach (i; 1 .. cast(size_t)n) {
                tPowers[i] = tPowers[i - 1] * tVec;
                oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
            }
            auto resX = splatSimd(0);
            auto resY = splatSimd(0);
            foreach (i; 0 .. cast(size_t)n) {
                auto coeff = splatSimd(cast(float)binomial(n - 1, i))
                    * oneMinusTPowers[n - 1 - i]
                    * tPowers[i];
                auto dx = splatSimd(derivX[i]);
                auto dy = splatSimd(derivY[i]);
                resX += coeff * dx;
                resY += coeff * dy;
            }
            storeVec(dstX, idx, resX);
            storeVec(dstY, idx, resY);
        }

        for (; idx < samples.length; ++idx) {
            float t = samples[idx];
            float resXScalar = 0;
            float resYScalar = 0;
            float oneMinusT = 1 - t;
            if (n > 0) {
                scalarTPowers[0] = 1;
                scalarOneMinus[0] = 1;
            }
            foreach (i; 1 .. cast(size_t)n) {
                scalarTPowers[i] = scalarTPowers[i - 1] * t;
                scalarOneMinus[i] = scalarOneMinus[i - 1] * oneMinusT;
            }
            foreach (i; 0 .. cast(size_t)n) {
                float coeff = cast(float)binomial(n - 1, i) *
                    scalarOneMinus[n - 1 - i] * scalarTPowers[i];
                resXScalar += coeff * derivX[i];
                resYScalar += coeff * derivY[i];
            }
            dstX[idx] = resXScalar;
            dstY[idx] = resYScalar;
        }
    }

    // Find the closest point on the Bezier curve
    override
    float closestPoint(vec2 point, int nSamples = 100) {
        float closestT = 0.0;
        import std.numeric;
        auto result = findLocalMin((float t)=>(this.point(t) - point).lengthSquared, 0f, 1f);
        closestT = result[0];
        return closestT;
    }

    T opCast(T: bool)() { return controlPoints.length > 0; }
}

class SplineCurve : Curve {
    // Spline control point array
    Vec2Array _controlPoints;

    // Cache: computed t -> point(t)
    vec2[float] pointCache;
    // Cache: computed t -> derivative(t)
    vec2[float] derivativeCache;

public:
    // Constructor
    this(Vec2Array controlPoints) {
        // Copy control points
        this.controlPoints = controlPoints.dup;
        // Initialize cache
        pointCache.clear();
        derivativeCache.clear();
    }

    // Interface impl: control point getter
    override
    ref Vec2Array controlPoints() { 
        return _controlPoints; 
    }

    // Interface impl: control point setter
    override
    void controlPoints(ref Vec2Array points) {
        this._controlPoints = points;
        // Clear cache when control points change
        pointCache.clear();
        derivativeCache.clear();
    }

    // Interface impl: point on spline (0 <= t <= 1)
    override
    vec2 point(float t) {
        // Reuse cache if present
        if (t in pointCache)
            return pointCache[t];

        Vec2Array tmp;
        float[1] sampleBuf;
        sampleBuf[0] = t;
        evaluatePoints(sampleBuf[], tmp);
        vec2 result = tmp.length ? tmp[0].toVector() : vec2(0, 0);
        pointCache[t] = result;
        return result;
    }

    // Interface impl: tangent on spline (derivative)
    override
    vec2 derivative(float t) {
        // Reuse cache if present
        if (t in derivativeCache)
            return derivativeCache[t];

        Vec2Array tmp;
        float[1] sampleBuf;
        sampleBuf[0] = t;
        evaluateDerivatives(sampleBuf[], tmp);
        vec2 result = tmp.length ? tmp[0].toVector() : vec2(0, 0);
        derivativeCache[t] = result;
        return result;
    }

    // Interface impl: find parameter t closest to the given point
    override
    float closestPoint(vec2 point, int nSamples = 100) {
        //float minDistanceSquared = float.max;
        float closestT = 0.0;
        import std.numeric;
        auto result = findLocalMin((float t)=>(this.point(t) - point).lengthSquared, 0f, 1f);
        closestT = result[0];
        return closestT;
    }

    override
    void evaluatePoints(const float[] samples, ref Vec2Array dst) {
        dst.length = samples.length;
        if (samples.length == 0) return;
        auto dstX = dst.lane(0);
        auto dstY = dst.lane(1);
        auto cpX = _controlPoints.lane(0);
        auto cpY = _controlPoints.lane(1);
        size_t len = _controlPoints.length;

        if (len < 2) {
            dstX[] = 0;
            dstY[] = 0;
            return;
        }

        auto half = splatSimd(0.5f);
        size_t idx = 0;
        if (len == 2) {
            auto ax = splatSimd(cpX[0]);
            auto ay = splatSimd(cpY[0]);
            auto bx = splatSimd(cpX[1]);
            auto by = splatSimd(cpY[1]);
            for (; idx + simdWidth <= samples.length; idx += simdWidth) {
                auto tVec = loadVec(samples, idx);
                auto oneMinus = splatSimd(1.0f) - tVec;
                auto resX = ax * oneMinus + bx * tVec;
                auto resY = ay * oneMinus + by * tVec;
                storeVec(dstX, idx, resX);
                storeVec(dstY, idx, resY);
            }
            for (; idx < samples.length; ++idx) {
                float t = samples[idx];
                dstX[idx] = cpX[0] * (1 - t) + cpX[1] * t;
                dstY[idx] = cpY[0] * (1 - t) + cpY[1] * t;
            }
            return;
        }

        for (; idx + simdWidth <= samples.length; idx += simdWidth) {
            SimdRepr lt;
            SimdRepr lt2;
            SimdRepr lt3;
            SimdRepr Ax;
            SimdRepr Ay;
            SimdRepr Bx;
            SimdRepr By;
            SimdRepr Cx;
            SimdRepr Cy;
            SimdRepr Dx;
            SimdRepr Dy;

            foreach (laneIdx; 0 .. simdWidth) {
                float t = samples[idx + laneIdx];
                float segment = t * (len - 1);
                int segmentIndex = cast(int)segment;
                int p1 = clamp(segmentIndex, 0, cast(int)len - 2);
                int p0 = max(0, p1 - 1);
                int p2 = min(cast(int)len - 1, p1 + 1);
                int p3 = min(cast(int)len - 1, p2 + 1);
                float ltScalar = segment - segmentIndex;
                float lt2Scalar = ltScalar * ltScalar;
                float lt3Scalar = lt2Scalar * ltScalar;

                float p0x = cpX[p0];
                float p0y = cpY[p0];
                float p1x = cpX[p1];
                float p1y = cpY[p1];
                float p2x = cpX[p2];
                float p2y = cpY[p2];
                float p3x = cpX[p3];
                float p3y = cpY[p3];

                lt.scalars[laneIdx] = ltScalar;
                lt2.scalars[laneIdx] = lt2Scalar;
                lt3.scalars[laneIdx] = lt3Scalar;
                Ax.scalars[laneIdx] = 2.0f * p1x;
                Ay.scalars[laneIdx] = 2.0f * p1y;
                Bx.scalars[laneIdx] = p2x - p0x;
                By.scalars[laneIdx] = p2y - p0y;
                Cx.scalars[laneIdx] = 2.0f * p0x - 5.0f * p1x + 4.0f * p2x - p3x;
                Cy.scalars[laneIdx] = 2.0f * p0y - 5.0f * p1y + 4.0f * p2y - p3y;
                Dx.scalars[laneIdx] = -p0x + 3.0f * p1x - 3.0f * p2x + p3x;
                Dy.scalars[laneIdx] = -p0y + 3.0f * p1y - 3.0f * p2y + p3y;
            }

            auto ltVec = lt.vec;
            auto lt2Vec = lt2.vec;
            auto lt3Vec = lt3.vec;
            auto resX = half * (Ax.vec + Bx.vec * ltVec + Cx.vec * lt2Vec + Dx.vec * lt3Vec);
            auto resY = half * (Ay.vec + By.vec * ltVec + Cy.vec * lt2Vec + Dy.vec * lt3Vec);
            storeVec(dstX, idx, resX);
            storeVec(dstY, idx, resY);
        }

        for (; idx < samples.length; ++idx) {
            float t = samples[idx];
            float segment = t * (len - 1);
            int segmentIndex = cast(int)segment;
            int p1 = clamp(segmentIndex, 0, cast(int)len - 2);
            int p0 = max(0, p1 - 1);
            int p2 = min(cast(int)len - 1, p1 + 1);
            int p3 = min(cast(int)len - 1, p2 + 1);
            float ltScalar = segment - segmentIndex;
            float lt2Scalar = ltScalar * ltScalar;
            float lt3Scalar = lt2Scalar * ltScalar;

            float p0x = cpX[p0];
            float p0y = cpY[p0];
            float p1x = cpX[p1];
            float p1y = cpY[p1];
            float p2x = cpX[p2];
            float p2y = cpY[p2];
            float p3x = cpX[p3];
            float p3y = cpY[p3];

            float AxScalar = 2.0f * p1x;
            float AyScalar = 2.0f * p1y;
            float BxScalar = p2x - p0x;
            float ByScalar = p2y - p0y;
            float CxScalar = 2.0f * p0x - 5.0f * p1x + 4.0f * p2x - p3x;
            float CyScalar = 2.0f * p0y - 5.0f * p1y + 4.0f * p2y - p3y;
            float DxScalar = -p0x + 3.0f * p1x - 3.0f * p2x + p3x;
            float DyScalar = -p0y + 3.0f * p1y - 3.0f * p2y + p3y;

            dstX[idx] = 0.5f * (AxScalar + BxScalar * ltScalar + CxScalar * lt2Scalar + DxScalar * lt3Scalar);
            dstY[idx] = 0.5f * (AyScalar + ByScalar * ltScalar + CyScalar * lt2Scalar + DyScalar * lt3Scalar);
        }
    }

    override
    void evaluateDerivatives(const float[] samples, ref Vec2Array dst) {
        dst.length = samples.length;
        if (samples.length == 0) return;
        auto dstX = dst.lane(0);
        auto dstY = dst.lane(1);
        auto cpX = _controlPoints.lane(0);
        auto cpY = _controlPoints.lane(1);
        size_t len = _controlPoints.length;

        if (len < 2) {
            dstX[] = 0;
            dstY[] = 0;
            return;
        }

        size_t idx = 0;
        if (len == 2) {
            float dx = cpX[1] - cpX[0];
            float dy = cpY[1] - cpY[0];
            auto dxVec = splatSimd(dx);
            auto dyVec = splatSimd(dy);
            for (; idx + simdWidth <= samples.length; idx += simdWidth) {
                storeVec(dstX, idx, dxVec);
                storeVec(dstY, idx, dyVec);
            }
            for (; idx < samples.length; ++idx) {
                dstX[idx] = dx;
                dstY[idx] = dy;
            }
            return;
        }

        auto half = splatSimd(0.5f);

        for (; idx + simdWidth <= samples.length; idx += simdWidth) {
            SimdRepr lt;
            SimdRepr lt2;
            SimdRepr Bx;
            SimdRepr By;
            SimdRepr Cx;
            SimdRepr Cy;
            SimdRepr Dx;
            SimdRepr Dy;

            foreach (laneIdx; 0 .. simdWidth) {
                float t = samples[idx + laneIdx];
                float segment = t * (len - 1);
                int segmentIndex = cast(int)segment;
                int p1 = clamp(segmentIndex, 0, cast(int)len - 2);
                int p0 = max(0, p1 - 1);
                int p2 = min(cast(int)len - 1, p1 + 1);
                int p3 = min(cast(int)len - 1, p2 + 1);
                float ltScalar = segment - segmentIndex;
                float lt2Scalar = ltScalar * ltScalar;

                float p0x = cpX[p0];
                float p0y = cpY[p0];
                float p1x = cpX[p1];
                float p1y = cpY[p1];
                float p2x = cpX[p2];
                float p2y = cpY[p2];
                float p3x = cpX[p3];
                float p3y = cpY[p3];

                lt.scalars[laneIdx] = ltScalar;
                lt2.scalars[laneIdx] = lt2Scalar;
                Bx.scalars[laneIdx] = p2x - p0x;
                By.scalars[laneIdx] = p2y - p0y;
                Cx.scalars[laneIdx] = 2.0f * p0x - 5.0f * p1x + 4.0f * p2x - p3x;
                Cy.scalars[laneIdx] = 2.0f * p0y - 5.0f * p1y + 4.0f * p2y - p3y;
                Dx.scalars[laneIdx] = -p0x + 3.0f * p1x - 3.0f * p2x + p3x;
                Dy.scalars[laneIdx] = -p0y + 3.0f * p1y - 3.0f * p2y + p3y;
            }

            auto ltVec = lt.vec;
            auto lt2Vec = lt2.vec;
            auto resX = half * (Bx.vec + splatSimd(2.0f) * Cx.vec * ltVec + splatSimd(3.0f) * Dx.vec * lt2Vec);
            auto resY = half * (By.vec + splatSimd(2.0f) * Cy.vec * ltVec + splatSimd(3.0f) * Dy.vec * lt2Vec);
            storeVec(dstX, idx, resX);
            storeVec(dstY, idx, resY);
        }

        for (; idx < samples.length; ++idx) {
            float t = samples[idx];
            float segment = t * (len - 1);
            int segmentIndex = cast(int)segment;
            int p1 = clamp(segmentIndex, 0, cast(int)len - 2);
            int p0 = max(0, p1 - 1);
            int p2 = min(cast(int)len - 1, p1 + 1);
            int p3 = min(cast(int)len - 1, p2 + 1);
            float ltScalar = segment - segmentIndex;
            float lt2Scalar = ltScalar * ltScalar;

            float p0x = cpX[p0];
            float p0y = cpY[p0];
            float p1x = cpX[p1];
            float p1y = cpY[p1];
            float p2x = cpX[p2];
            float p2y = cpY[p2];
            float p3x = cpX[p3];
            float p3y = cpY[p3];

            float BxScalar = p2x - p0x;
            float ByScalar = p2y - p0y;
            float CxScalar = 2.0f * p0x - 5.0f * p1x + 4.0f * p2x - p3x;
            float CyScalar = 2.0f * p0y - 5.0f * p1y + 4.0f * p2y - p3y;
            float DxScalar = -p0x + 3.0f * p1x - 3.0f * p2x + p3x;
            float DyScalar = -p0y + 3.0f * p1y - 3.0f * p2y + p3y;

            dstX[idx] = 0.5f * (BxScalar + 2.0f * CxScalar * ltScalar + 3.0f * DxScalar * lt2Scalar);
            dstY[idx] = 0.5f * (ByScalar + 2.0f * CyScalar * ltScalar + 3.0f * DyScalar * lt2Scalar);
        }
    }
}
