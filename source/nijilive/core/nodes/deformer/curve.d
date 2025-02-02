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
        float minDistanceSquared = float.max;
        float closestT = 0.0;
        for (int i = 0; i < nSamples; ++i) {
            float t = i / float(nSamples - 1);
            vec2 bezierPoint = this.point(t);
            float distanceSquared = (bezierPoint - point).lengthSquared;
            if (distanceSquared < minDistanceSquared) {
                minDistanceSquared = distanceSquared;
                closestT = t;
            }
        }
        return closestT;
    }

    T opCast(T: bool)() { return controlPoints.length > 0; }
}

class SplineCurve : Curve {
    vec2[] _controlPoints;
    vec2[float] pointCache;
    vec2[float] derivativeCache;

public:
    this(vec2[] controlPoints) {
        this.controlPoints = controlPoints.dup;
        pointCache.clear();
        derivativeCache.clear();
    }

    override
    ref vec2[] controlPoints() { return _controlPoints; }

    override
    void controlPoints(ref vec2[] points) {
        this._controlPoints = points;
        pointCache.clear();
        derivativeCache.clear();
    }

    override
    vec2 point(float t) {
        if (t in pointCache)
            return pointCache[t];

        int p0, p1, p2, p3;
        float lt;

        // Handling case when length of control points are less than tree.
        if (controlPoints.length < 2) {
            return vec2(0.0, 0.0);
        }

        if (controlPoints.length == 2) {
            // linear interpolation in case of two vertices.
            vec2 a = controlPoints[0];
            vec2 b = controlPoints[1];
            return a * (1 - t) + b * t;
        }

        // Handling normal case
        float segment = t * (controlPoints.length - 1);
        int segmentIndex = cast(int)segment;

        p1 = clamp(segmentIndex, 0, cast(int)controlPoints.length - 2);
        p0 = max(0, p1 - 1);
        p2 = min(controlPoints.length - 1, p1 + 1);
        p3 = min(controlPoints.length - 1, p2 + 1);

        lt = segment - segmentIndex;

        // Calculating Catmull-Rom factor.
        vec2 a = 2.0 * controlPoints[p1];
        vec2 b = controlPoints[p2] - controlPoints[p0];
        vec2 c = 2.0 * controlPoints[p0] - 5.0 * controlPoints[p1] + 4.0 * controlPoints[p2] - controlPoints[p3];
        vec2 d = -controlPoints[p0] + 3.0 * controlPoints[p1] - 3.0 * controlPoints[p2] + controlPoints[p3];

        // points on spline curve
        vec2 result = 0.5 * (a + (b * lt) + (c * lt * lt) + (d * lt * lt * lt));
        pointCache[t] = result;
        return result;
    }

    // Calculating the derivative (tangent vector) of a spline curve
    override
    vec2 derivative(float t) {
        if (t in derivativeCache)
            return derivativeCache[t];

        int p0, p1, p2, p3;
        float lt;

        // Handling case when length of control points are less than tree.
        if (controlPoints.length < 2) {
            return vec2(0.0, 0.0);
        }

        if (controlPoints.length == 2) {
            return controlPoints[1] - controlPoints[0];
        }

        // Handling normal case.
        float segment = t * (controlPoints.length - 1);
        int segmentIndex = cast(int)segment;

        p1 = clamp(segmentIndex, 0, cast(int)controlPoints.length - 2);
        p0 = max(0, p1 - 1);
        p2 = min(controlPoints.length - 1, p1 + 1);
        p3 = min(controlPoints.length - 1, p2 + 1);

        lt = segment - segmentIndex;

        vec2 b = controlPoints[p2] - controlPoints[p0];
        vec2 c = 2.0 * (2.0 * controlPoints[p0] - 5.0 * controlPoints[p1] + 4.0 * controlPoints[p2] - controlPoints[p3]);
        vec2 d = 3.0 * (-controlPoints[p0] + 3.0 * controlPoints[p1] - 3.0 * controlPoints[p2] + controlPoints[p3]);

        vec2 result = 0.5 * (b + (2.0 * c * lt) + (3.0 * d * lt * lt));
        derivativeCache[t] = result;
        return result;
    }

    override
    float closestPoint(vec2 point, int nSamples = 100) {
        float minDistanceSquared = float.max;
        float closestT = 0.0;
        for (int i = 0; i < nSamples; ++i) {
            float t = i / float(nSamples - 1);
            vec2 splinePoint = this.point(t);
            float distanceSquared = (splinePoint - point).lengthSquared;
            if (distanceSquared < minDistanceSquared) {
                minDistanceSquared = distanceSquared;
                closestT = t;
            }
        }
        return closestT;
    }
}
