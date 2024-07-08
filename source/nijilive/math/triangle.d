module nijilive.math.triangle;
import nijilive.math;
import nijilive.core.meshdata;
import nijilive.core.nodes.defstack;
import inmath;
import std.math;
import std.algorithm;
import std.array : array;
import std.conv : to;


bool isPointInTriangle(vec2 pt, vec2[3] triangle) {
    float sign (ref vec2 p1, ref vec2 p2, ref vec2 p3) {
        return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
    }
    vec2 p1 = triangle[0];
    vec2 p2 = triangle[1];
    vec2 p3 = triangle[2];

    auto d1 = sign(pt, p1, p2);
    auto d2 = sign(pt, p2, p3);
    auto d3 = sign(pt, p3, p1);

    auto hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    auto hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);

    return !(hasNeg && hasPos);
}


int[] findSurroundingTriangle(vec2 pt, ref MeshData bindingMesh) {
    bool isPointInTriangle(vec2 pt, int[] triangle) {
        float sign (ref vec2 p1, ref vec2 p2, ref vec2 p3) {
            return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
        }
        vec2 p1 = bindingMesh.vertices[triangle[0]];
        vec2 p2 = bindingMesh.vertices[triangle[1]];
        vec2 p3 = bindingMesh.vertices[triangle[2]];

        auto d1 = sign(pt, p1, p2);
        auto d2 = sign(pt, p2, p3);
        auto d3 = sign(pt, p3, p1);

        auto hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
        auto hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);

        return !(hasNeg && hasPos);
    }
    int i = 0;
    int[] triangle = [0, 1, 2];
    while (i < bindingMesh.indices.length) {
        triangle[0] = bindingMesh.indices[i];
        triangle[1] = bindingMesh.indices[i+1];
        triangle[2] = bindingMesh.indices[i+2];
        if (isPointInTriangle(pt, triangle)) {
            return triangle;
        }
        i += 3;
    }
    return null;
}


// Calculate offset of point in coordinates of triangle.
vec2 calcOffsetInTriangleCoords(vec2 pt, ref MeshData bindingMesh, ref int[] triangle) {
    if( (pt - bindingMesh.vertices[triangle[0]]).lengthSquared > (pt - bindingMesh.vertices[triangle[1]]).lengthSquared) {
        swap(triangle[0], triangle[1]);
    }
    if( (pt - bindingMesh.vertices[triangle[0]]).lengthSquared > (pt - bindingMesh.vertices[triangle[2]]).lengthSquared) {
        swap(triangle[0], triangle[2]);
    }
    auto p1 = bindingMesh.vertices[triangle[0]];
    auto p2 = bindingMesh.vertices[triangle[1]];
    auto p3 = bindingMesh.vertices[triangle[2]];
    vec2 axis0 = p2 - p1;
    float axis0len = axis0.length;
    axis0 /= axis0.length;
    vec2 axis1 = p3 - p1;
    float axis1len = axis1.length;
    axis1 /= axis1.length;

    auto relPt = pt - p1;
    if (relPt.lengthSquared == 0)
        return vec2(0, 0);
    float cosA = dot(axis0, axis1);
    if (cosA == 0) {
        return vec2(dot(relPt, axis0), dot(relPt, axis1));
    } else {
        float argA = acos(cosA);
        float sinA = sin(argA);
        float tanA = tan(argA);
        float cosB = dot(axis0, relPt) / relPt.length;
        float argB = acos(cosB);
        float sinB = sin(argB);
        
        vec2 ortPt = vec2(relPt.length * cosB, relPt.length * sinB);
        
        mat2 H = mat2([1, -1/tanA, 0, 1/sinA]);
        auto result = H * ortPt;

        return result;
    }
}

private {
mat3 calculateAffineTransform(vec2[] vertices, int[] triangle, vec2[] deform) {
    auto p0 = vertices[triangle[0]];
    auto p1 = vertices[triangle[1]];
    auto p2 = vertices[triangle[2]];
    mat3 original = mat3(
        p0.x, p1.x, p2.x,
        p0.y, p1.y, p2.y,
        1.0f, 1.0f, 1.0f
    );
    auto p3 = p0 + deform[triangle[0]];
    auto p4 = p1 + deform[triangle[1]];
    auto p5 = p2 + deform[triangle[2]];

    mat3 transformed = mat3(
        p3.x, p4.x, p5.x,
        p3.y, p4.y, p5.y,
        1.0f, 1.0f, 1.0f);

    mat3 affineTransform = transformed * original.inverse();
    return affineTransform;
}

vec2 applyAffineTransform(mat3 transform, vec2 point) {
    vec3 pointHomogeneous = vec3(point, 1.0);
    vec3 transformedPointHomogeneous = transform * pointHomogeneous;
    return transformedPointHomogeneous.xy;
}

float calculateAngle(vec2 A, vec2 B) {
    return atan2(B.y - A.y, B.x - A.x);
}
}

bool nlCalculateTransformInTriangle(vec2[] vertices, int[] triangle, vec2[] deform, vec2 target, 
        out vec2 target_prime, out float rotationAngle_vert, out float rotationAngle_horz) {
    mat3 affineTransform = calculateAffineTransform(vertices, triangle, deform);
    target_prime = applyAffineTransform(affineTransform, target);

    // Vertical unit vector rotation
    vec2 vert = vec2(0, 1);
    vec2 target_vert = target + vert;
    vec2 target_vert_prime = applyAffineTransform(affineTransform, target_vert);

    // Horizontal unit vector rotation
    vec2 horz = vec2(1, 0);
    vec2 target_horz = target + horz;
    vec2 target_horz_prime = applyAffineTransform(affineTransform, target_horz);

    // Calculate angles from above vectors.
    float originalAngle_vert = calculateAngle(target, target_vert);
    float transformedAngle_vert = calculateAngle(target_prime, target_vert_prime);
    rotationAngle_vert = transformedAngle_vert - originalAngle_vert;

    float originalAngle_horz = calculateAngle(target, target_horz);
    float transformedAngle_horz = calculateAngle(target_prime, target_horz_prime);
    rotationAngle_horz = transformedAngle_horz - originalAngle_horz;

    return true;
}