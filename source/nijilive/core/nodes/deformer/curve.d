module nijilive.core.nodes.deformer.curve;

import nijilive.math;

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
        float[] tPowers;
        float[] oneMinusTPowers;
        tPowers.length = cast(size_t)(n + 1);
        oneMinusTPowers.length = cast(size_t)(n + 1);

        foreach (idx, t; samples) {
            float resX = 0;
            float resY = 0;
            float oneMinusT = 1 - t;
            if (tPowers.length)
                tPowers[0] = 1;
            if (oneMinusTPowers.length)
                oneMinusTPowers[0] = 1;
            for (int i = 1; i <= n; ++i) {
                tPowers[i] = tPowers[i - 1] * t;
                oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
            }
            for (int i = 0; i <= n; ++i) {
                float binomialCoeff = cast(float)binomial(n, i);
                float coeff = binomialCoeff * oneMinusTPowers[n - i] * tPowers[i];
                resX += coeff * cpX[i];
                resY += coeff * cpY[i];
            }
            dstX[idx] = resX;
            dstY[idx] = resY;
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
        float[] tPowers;
        float[] oneMinusTPowers;
        tPowers.length = cast(size_t)(n);
        oneMinusTPowers.length = cast(size_t)(n);

        foreach (idx, t; samples) {
            float resX = 0;
            float resY = 0;
            float oneMinusT = 1 - t;
            if (tPowers.length)
                tPowers[0] = 1;
            if (oneMinusTPowers.length)
                oneMinusTPowers[0] = 1;
            for (int i = 1; i < n; ++i) {
                tPowers[i] = tPowers[i - 1] * t;
                oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
            }
            for (int i = 0; i < n; ++i) {
                float binomialCoeff = cast(float)binomial(n - 1, i);
                float coeff = binomialCoeff * oneMinusTPowers[n - 1 - i] * tPowers[i];
                resX += coeff * derivX[i];
                resY += coeff * derivY[i];
            }
            dstX[idx] = resX;
            dstY[idx] = resY;
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
    // スプラインの制御点配列
    Vec2Array _controlPoints;

    // キャッシュ: 計算済みの t => point(t)
    vec2[float] pointCache;
    // キャッシュ: 計算済みの t => derivative(t)
    vec2[float] derivativeCache;

public:
    // コンストラクタ
    this(Vec2Array controlPoints) {
        // 制御点をコピー
        this.controlPoints = controlPoints.dup;
        // キャッシュの初期化
        pointCache.clear();
        derivativeCache.clear();
    }

    // インターフェイス実装: 制御点のゲッター
    override
    ref Vec2Array controlPoints() { 
        return _controlPoints; 
    }

    // インターフェイス実装: 制御点のセッター
    override
    void controlPoints(ref Vec2Array points) {
        this._controlPoints = points;
        // 制御点変更時はキャッシュをクリア
        pointCache.clear();
        derivativeCache.clear();
    }

    // インターフェイス実装: スプライン上の点 (0 <= t <= 1)
    override
    vec2 point(float t) {
        // すでにキャッシュにあれば再利用
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

    // インターフェイス実装: スプライン上の接線（微分）
    override
    vec2 derivative(float t) {
        // すでにキャッシュにあれば再利用
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

    // インターフェイス実装: 与えられた点に最も近いパラメータ t を探索
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

        foreach (idx, t; samples) {
            if (len < 2) {
                dstX[idx] = 0;
                dstY[idx] = 0;
                continue;
            }
            if (len == 2) {
                float ax = cpX[0];
                float ay = cpY[0];
                float bx = cpX[1];
                float by = cpY[1];
                dstX[idx] = ax * (1 - t) + bx * t;
                dstY[idx] = ay * (1 - t) + by * t;
                continue;
            }

            float segment = t * (len - 1);
            int segmentIndex = cast(int)segment;
            int p1 = clamp(segmentIndex, 0, cast(int)len - 2);
            int p0 = max(0, p1 - 1);
            int p2 = min(cast(int)len - 1, p1 + 1);
            int p3 = min(cast(int)len - 1, p2 + 1);
            float lt = segment - segmentIndex;
            float lt2 = lt * lt;
            float lt3 = lt2 * lt;

            float p0x = cpX[p0];
            float p0y = cpY[p0];
            float p1x = cpX[p1];
            float p1y = cpY[p1];
            float p2x = cpX[p2];
            float p2y = cpY[p2];
            float p3x = cpX[p3];
            float p3y = cpY[p3];

            float Ax = 2.0f * p1x;
            float Ay = 2.0f * p1y;
            float Bx = p2x - p0x;
            float By = p2y - p0y;
            float Cx = 2.0f * p0x - 5.0f * p1x + 4.0f * p2x - p3x;
            float Cy = 2.0f * p0y - 5.0f * p1y + 4.0f * p2y - p3y;
            float Dx = -p0x + 3.0f * p1x - 3.0f * p2x + p3x;
            float Dy = -p0y + 3.0f * p1y - 3.0f * p2y + p3y;

            dstX[idx] = 0.5f * (Ax + Bx * lt + Cx * lt2 + Dx * lt3);
            dstY[idx] = 0.5f * (Ay + By * lt + Cy * lt2 + Dy * lt3);
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

        foreach (idx, t; samples) {
            if (len < 2) {
                dstX[idx] = 0;
                dstY[idx] = 0;
                continue;
            }
            if (len == 2) {
                dstX[idx] = cpX[1] - cpX[0];
                dstY[idx] = cpY[1] - cpY[0];
                continue;
            }

            float segment = t * (len - 1);
            int segmentIndex = cast(int)segment;
            int p1 = clamp(segmentIndex, 0, cast(int)len - 2);
            int p0 = max(0, p1 - 1);
            int p2 = min(cast(int)len - 1, p1 + 1);
            int p3 = min(cast(int)len - 1, p2 + 1);
            float lt = segment - segmentIndex;
            float lt2 = lt * lt;

            float p0x = cpX[p0];
            float p0y = cpY[p0];
            float p1x = cpX[p1];
            float p1y = cpY[p1];
            float p2x = cpX[p2];
            float p2y = cpY[p2];
            float p3x = cpX[p3];
            float p3y = cpY[p3];

            float Bx = p2x - p0x;
            float By = p2y - p0y;
            float Cx = 2.0f * p0x - 5.0f * p1x + 4.0f * p2x - p3x;
            float Cy = 2.0f * p0y - 5.0f * p1y + 4.0f * p2y - p3y;
            float Dx = -p0x + 3.0f * p1x - 3.0f * p2x + p3x;
            float Dy = -p0y + 3.0f * p1y - 3.0f * p2y + p3y;

            dstX[idx] = 0.5f * (Bx + 2.0f * Cx * lt + 3.0f * Dx * lt2);
            dstY[idx] = 0.5f * (By + 2.0f * Cy * lt + 3.0f * Dy * lt2);
        }
    }
}
