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
    ref vec2[] controlPoints();
    void controlPoints(ref vec2[] points);
    vec2 derivative(float t);
}

class BezierCurve : Curve{
    vec2[] _controlPoints;
    vec2[] derivatives; // Precomputed Bezier curve derivatives
    vec2[float] pointCache;
public:
    this(vec2[] controlPoints) {
        this.controlPoints = controlPoints.dup;
        this.derivatives = new vec2[controlPoints.length > 0? controlPoints.length - 1: 0];
        calculateDerivatives();
    }

    override
    ref vec2[] controlPoints() { return _controlPoints; }
    
    override
    void controlPoints(ref vec2[] points) { this._controlPoints = points; }

    // Compute the point on the Bezier curve
    override
    vec2 point(float t) {
        if (t in pointCache)
            return pointCache[t];
        long n = controlPoints.length - 1;
        vec2 result = vec2(0.0, 0.0);
        float oneMinusT = 1 - t;
        float[] tPowers = new float[n + 1];
        float[] oneMinusTPowers = new float[n + 1];
        tPowers[0] = 1;
        oneMinusTPowers[0] = 1;
        for (int i = 1; i <= n; ++i) {
            tPowers[i] = tPowers[i - 1] * t;
            oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
        }
        for (int i = 0; i <= n; ++i) {
            float binomialCoeff = float(binomial(n, i));
            result += binomialCoeff * oneMinusTPowers[n - i] * tPowers[i] * controlPoints[i];
        }
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
        long n = derivatives.length;
        vec2 result = vec2(0.0, 0.0);
        float oneMinusT = 1 - t;
        float[] tPowers = new float[n];
        float[] oneMinusTPowers = new float[n];
        tPowers[0] = 1;
        oneMinusTPowers[0] = 1;
        for (int i = 1; i < n; ++i) {
            tPowers[i] = tPowers[i - 1] * t;
            oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
        }
        for (int i = 0; i < n; ++i) {
            float binomialCoeff = float(binomial(n - 1, i));
            result += binomialCoeff * oneMinusTPowers[n - 1 - i] * tPowers[i] * derivatives[i];
        }
        return result;
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
    vec2[] _controlPoints;

    // キャッシュ: 計算済みの t => point(t)
    vec2[float] pointCache;
    // キャッシュ: 計算済みの t => derivative(t)
    vec2[float] derivativeCache;

public:
    // コンストラクタ
    this(vec2[] controlPoints) {
        // 制御点をコピー
        this.controlPoints = controlPoints.dup;
        // キャッシュの初期化
        pointCache.clear();
        derivativeCache.clear();
    }

    // インターフェイス実装: 制御点のゲッター
    override
    ref vec2[] controlPoints() { 
        return _controlPoints; 
    }

    // インターフェイス実装: 制御点のセッター
    override
    void controlPoints(ref vec2[] points) {
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

        int p0, p1, p2, p3;
        float lt;

        // 制御点が2つ未満の場合 (1点 or 0点)
        // → (0,0) を返す
        if (_controlPoints.length < 2) {
            vec2 fallback = vec2(0.0, 0.0);
            pointCache[t] = fallback;
            return fallback;
        }

        // 制御点がちょうど2点の場合 → 線形補間 (Lerp)
        if (_controlPoints.length == 2) {
            vec2 a = _controlPoints[0];
            vec2 b = _controlPoints[1];
            vec2 linear = a * (1 - t) + b * t;
            pointCache[t] = linear;
            return linear;
        }

        // 3点以上 → 通常の Catmull-Rom スプライン
        float segment = t * (_controlPoints.length - 1);
        int segmentIndex = cast(int)segment;

        // p1 が「該当セグメントの始点」を指す
        // p0, p2, p3 はその前後の点
        p1 = clamp(segmentIndex, 0, cast(int)_controlPoints.length - 2);
        p0 = max(0, p1 - 1);
        p2 = min(_controlPoints.length - 1, p1 + 1);
        p3 = min(_controlPoints.length - 1, p2 + 1);

        // ローカル t (セグメント内の進捗)
        lt = segment - segmentIndex;

        // Catmull-Rom スプライン (t=0.5) の標準係数
        vec2 A = 2.0 * _controlPoints[p1];
        vec2 B = _controlPoints[p2] - _controlPoints[p0];
        vec2 C = 2.0 * _controlPoints[p0]
               - 5.0 * _controlPoints[p1]
               + 4.0 * _controlPoints[p2]
               - _controlPoints[p3];
        vec2 D = -_controlPoints[p0]
               + 3.0 * _controlPoints[p1]
               - 3.0 * _controlPoints[p2]
               + _controlPoints[p3];

        // p(t) = 0.5 * [A + B t + C t^2 + D t^3]
        vec2 result = 0.5 * (A
                           + B * lt
                           + C * lt * lt
                           + D * lt * lt * lt);

        // キャッシュに保存
        pointCache[t] = result;
        return result;
    }

    // インターフェイス実装: スプライン上の接線（微分）
    override
    vec2 derivative(float t) {
        // すでにキャッシュにあれば再利用
        if (t in derivativeCache)
            return derivativeCache[t];

        int p0, p1, p2, p3;
        float lt;

        // 制御点が2つ未満 → (0,0) を返す
        if (_controlPoints.length < 2) {
            vec2 fallback = vec2(0.0, 0.0);
            derivativeCache[t] = fallback;
            return fallback;
        }

        // 制御点が2点しかない → 接線は一定 (b - a)
        if (_controlPoints.length == 2) {
            vec2 deriv2 = _controlPoints[1] - _controlPoints[0];
            derivativeCache[t] = deriv2;
            return deriv2;
        }

        // 3点以上 → 通常の Catmull-Rom
        float segment = t * (_controlPoints.length - 1);
        int segmentIndex = cast(int)segment;

        p1 = clamp(segmentIndex, 0, cast(int)_controlPoints.length - 2);
        p0 = max(0, p1 - 1);
        p2 = min(_controlPoints.length - 1, p1 + 1);
        p3 = min(_controlPoints.length - 1, p2 + 1);

        lt = segment - segmentIndex;

        // point() で使った A, B, C, D のうち、
        // derivative で必要なのは B, C, D のみ
        // (C, D は掛け算を外しておく)
        vec2 B = _controlPoints[p2] - _controlPoints[p0];
        vec2 C = 2.0 * _controlPoints[p0]
               - 5.0 * _controlPoints[p1]
               + 4.0 * _controlPoints[p2]
               - _controlPoints[p3];
        vec2 D = -_controlPoints[p0]
               + 3.0 * _controlPoints[p1]
               - 3.0 * _controlPoints[p2]
               + _controlPoints[p3];

        // p(t) = 0.5 * [A + B t + C t^2 + D t^3]
        // → p'(t) = 0.5 * [B + 2 C t + 3 D t^2]
        vec2 result = 0.5 * (
            B
          + 2.0 * C * lt
          + 3.0 * D * lt * lt
        );

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
}