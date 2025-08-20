/*
    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
#version 330
uniform mat4 mvp;
uniform vec2 offset;

layout(location = 0) in vec2 verts;
layout(location = 1) in vec2 uvs;
layout(location = 2) in vec2 deform;

uniform vec2 splits;
uniform float animation;
uniform float frame;

out vec2 texUVs;

// GPU Path Deformer inputs (same as basic.vert)
uniform int pathEnabled;               // 0: off, 1: on
uniform int pathCurveType;             // 0: Bezier, 1: Spline
uniform int pathNumCP;                 // number of control points
uniform mat4 pathCenter;               // deformer.inverseMatrix * target.transform.matrix
uniform mat4 pathCenterInv;            // inverse(pathCenter) precomputed on CPU
uniform samplerBuffer pathTBuf;        // per-vertex t values
uniform samplerBuffer pathOrigCPBuf;   // original/prev curve control points (RG32F)
uniform samplerBuffer pathDefCPBuf;    // deformed curve control points (RG32F)
uniform int pathDynamic;               // 0: apply before child deform, 1: after

vec2 fetchCPOrig(int i) { return texelFetch(pathOrigCPBuf, i).xy; }
vec2 fetchCPDef(int i) { return texelFetch(pathDefCPBuf, i).xy; }

vec2 bezierPoint(float t, bool defCurve) {
    int n = pathNumCP - 1;
    if (n < 0) return vec2(0.0);
    float oneMinusT = 1.0 - t;
    float tPow[32]; float omPow[32]; tPow[0]=1.0; omPow[0]=1.0;
    for (int i=1;i<=n && i<32;i++){ tPow[i]=tPow[i-1]*t; omPow[i]=omPow[i-1]*oneMinusT; }
    vec2 res = vec2(0.0);
    float coeff = 1.0;
    for (int i=0;i<=n;i++) {
        if (i==0) coeff = 1.0; else coeff = coeff * float(n - (i-1)) / float(i);
        vec2 cp = defCurve? fetchCPDef(i): fetchCPOrig(i);
        res += coeff * omPow[n-i] * tPow[i] * cp;
    }
    return res;
}
vec2 bezierDerivative(float t, bool defCurve) {
    int n = pathNumCP - 1; if (n <= 0) return vec2(0.0);
    float oneMinusT = 1.0 - t; float tPow[32]; float omPow[32]; tPow[0]=1.0; omPow[0]=1.0;
    for (int i=1;i<n && i<32;i++){ tPow[i]=tPow[i-1]*t; omPow[i]=omPow[i-1]*oneMinusT; }
    vec2 res = vec2(0.0); float coeff=1.0;
    for (int i=0;i<n;i++){
        if (i==0) coeff=1.0; else coeff = coeff * float((n-1) - (i-1)) / float(i);
        vec2 cp0 = defCurve? fetchCPDef(i): fetchCPOrig(i);
        vec2 cp1 = defCurve? fetchCPDef(i+1): fetchCPOrig(i+1);
        vec2 d = (cp1 - cp0) * float(n);
        res += coeff * omPow[(n-1)-i] * tPow[i] * d;
    }
    return res;
}
void catmullRomParams(float t, out int p0, out int p1, out int p2, out int p3, out float lt) {
    float segf = t * float(pathNumCP - 1);
    int seg = int(floor(segf));
    p1 = clamp(seg, 0, pathNumCP - 2);
    p0 = max(0, p1 - 1); p2 = min(pathNumCP - 1, p1 + 1); p3 = min(pathNumCP - 1, p2 + 1);
    lt = segf - float(seg);
}
vec2 splinePoint(float t, bool defCurve) {
    if (pathNumCP < 2) return vec2(0.0);
    if (pathNumCP == 2) { vec2 a = defCurve? fetchCPDef(0): fetchCPOrig(0); vec2 b = defCurve? fetchCPDef(1): fetchCPOrig(1); return mix(a,b,t);}    
    int p0,p1,p2,p3; float lt; catmullRomParams(t, p0,p1,p2,p3, lt);
    vec2 P0 = defCurve? fetchCPDef(p0): fetchCPOrig(p0);
    vec2 P1 = defCurve? fetchCPDef(p1): fetchCPOrig(p1);
    vec2 P2 = defCurve? fetchCPDef(p2): fetchCPOrig(p2);
    vec2 P3 = defCurve? fetchCPDef(p3): fetchCPOrig(p3);
    vec2 A = 2.0*P1; vec2 B = P2 - P0; vec2 C = 2.0*P0 - 5.0*P1 + 4.0*P2 - P3; vec2 D = -P0 + 3.0*P1 - 3.0*P2 + P3;
    return 0.5*(A + B*lt + C*lt*lt + D*lt*lt*lt);
}
vec2 splineDerivative(float t, bool defCurve) {
    if (pathNumCP < 2) return vec2(0.0);
    if (pathNumCP == 2) { vec2 a = defCurve? fetchCPDef(0): fetchCPOrig(0); vec2 b = defCurve? fetchCPDef(1): fetchCPOrig(1); return b-a; }
    int p0,p1,p2,p3; float lt; catmullRomParams(t, p0,p1,p2,p3, lt);
    vec2 P0 = defCurve? fetchCPDef(p0): fetchCPOrig(p0);
    vec2 P1 = defCurve? fetchCPDef(p1): fetchCPOrig(p1);
    vec2 P2 = defCurve? fetchCPDef(p2): fetchCPOrig(p2);
    vec2 P3 = defCurve? fetchCPDef(p3): fetchCPOrig(p3);
    vec2 B = P2 - P0; vec2 C = 2.0*P0 - 5.0*P1 + 4.0*P2 - P3; vec2 D = -P0 + 3.0*P1 - 3.0*P2 + P3;
    return 0.5*(B + 2.0*C*lt + 3.0*D*lt*lt);
}

void main() {
    vec2 baseLocal = vec2(verts.x - offset.x, verts.y - offset.y);
    vec2 local = baseLocal + deform;
    if (pathEnabled == 1) {
        float t = texelFetch(pathTBuf, gl_VertexID).x;
        vec2 sourceLocal = (pathDynamic == 1) ? local : baseLocal;
        vec2 cVertex = (pathCenter * vec4(sourceLocal, 0.0, 1.0)).xy;
        vec2 C0 = (pathCurveType == 0) ? bezierPoint(t, false) : splinePoint(t, false);
        vec2 T0 = normalize((pathCurveType == 0) ? bezierDerivative(t, false) : splineDerivative(t, false));
        vec2 N0 = vec2(-T0.y, T0.x);
        float dN = dot(cVertex - C0, N0);
        float dT = dot(cVertex - C0, T0);
        vec2 C1 = (pathCurveType == 0) ? bezierPoint(t, true) : splinePoint(t, true);
        vec2 T1 = normalize((pathCurveType == 0) ? bezierDerivative(t, true) : splineDerivative(t, true));
        vec2 N1 = vec2(-T1.y, T1.x);
        vec2 cNew = C1 + N1 * dN + T1 * dT;
        vec2 localNew = (pathCenterInv * vec4(cNew, 0.0, 1.0)).xy;
        local = (pathDynamic == 1) ? localNew : (localNew + deform);
    }
    gl_Position = mvp * vec4(local, 0, 1);
    texUVs = vec2((uvs.x/splits.x)*frame, (uvs.y/splits.y)*animation);
}
