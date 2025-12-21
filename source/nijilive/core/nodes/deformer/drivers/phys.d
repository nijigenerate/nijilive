module nijilive.core.nodes.deformer.drivers.phys;

import nijilive.core.nodes.deformer.path;
import nijilive.math;
import std.math;
import std.typecons : tuple; // Import for tuple
import nijilive; // Import for deltaTime
import std.algorithm;
import std.array;
import std.stdio : writeln;
import std.conv : to;
import fghj;

private bool isFiniteVec(vec2 v) {
    return v.x.isFinite && v.y.isFinite;
}

bool guardFinite(PathDeformer deformer, string context, float value) {
    if (!value.isFinite) {
        return false;
    }
    return true;
}

bool guardFinite(PathDeformer deformer, string context, vec2 value, size_t index = size_t.max) {
    if (!isFiniteVec(value)) {
        return false;
    }
    return true;
}

interface PhysicsDriver : ISerializable {
    void setup();
    void reset();
    void enforce(vec2 force);
    void rotate(float angle);
    void update();
    void updateDefaultShape();
    void retarget(PathDeformer deformer);
    void serializeSelfImpl(ref InochiSerializer serializer); 
    SerdeException deserializeFromFghj(Fghj data);
    void serialize(S)(ref S serializer) {
        auto state = serializer.structBegin();

        serializeSelfImpl(serializer);
        serializer.structEnd(state);        
    }
    void copyFrom(PhysicsDriver src);
}

private {
    float screenToPhysicsY(float y) {
        return -y; // Invert y-coordinate for physics calculations
    }

    float physicsToScreenY(float y) {
        return -y; // Convert back to screen coordinates
    }

}

class ConnectedPendulumDriver : PhysicsDriver {
    vec2 externalForce = vec2(0, 0); // External force vector
    float worldAngle = 0.0; // Rotation angle of the coordinate system

    override
    void reset() {
        externalForce = vec2(0, 0);
    }

    void rotate(float angle) {
        if (!guardFinite(deformer, "pendulum:rotateAngle", angle)) {
            return;
        }
        worldAngle = -angle;
    }

    override
    void enforce(vec2 force) {
        if (!guardFinite(deformer, "pendulum:enforceForce", force)) {
            return;
        }
        vec2 scaled = force * inputScale;
        if (!guardFinite(deformer, "pendulum:enforceScaled", scaled)) {
            return;
        }
        externalForce = scaled;
    }
    PathDeformer deformer;
    float[] angles;
    float[] initialAngles;
    float[] angularVelocities;
    float[] lengths;
    Vec2Array physDeformation;
    float damping = 1.0;
    float restoreConstant = 300;
    float timeStep = 0.01;
    float gravity = 9.8; // Gravitational acceleration
    float inputScale = 0.01;
    float propagateScale = 0.2;
    vec2 base;

    this(PathDeformer deformer) {
        this.deformer = deformer;
    }

    override
    void retarget(PathDeformer deformer) {
        this.deformer = cast(PathDeformer)deformer;
        setup();
    }

    override
    void setup() {
        if (deformer.vertices.length < 2) return;
        // Initialize angles and lengths based on original control points
        updateDefaultShape();
        if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) {
            return;
        }
        angles = initialAngles.dup;
        angularVelocities = new float[angles.length];
        foreach (i; 0..angularVelocities.length) {
            angularVelocities[i] = 0;
        }
        physDeformation.length = deformer.vertices.length;
        physDeformation[] = vec2(0, 0);
        base = vec2(deformer.originalCurve.controlPoints[0].x, screenToPhysicsY(deformer.originalCurve.controlPoints[0].y));
        if (!guardFinite(deformer, "pendulum:base", base, 0)) {
            return;
        }
    }

    override
    void updateDefaultShape() {
        Vec2Array physicsControlPoints;
        foreach (i, p; deformer.originalCurve.controlPoints) {
            vec2 phys = vec2(p.x, screenToPhysicsY(p.y));
            if (!guardFinite(deformer, "pendulum:controlPoint", phys, i)) {
                return;
            }
            physicsControlPoints ~= phys;
        }
        auto initialAnglesAndLengths = extractAnglesAndLengths(physicsControlPoints);
        initialAngles = initialAnglesAndLengths[0];
        lengths = initialAnglesAndLengths[1];
        foreach (i, angle; initialAngles) {
            if (!guardFinite(deformer, "pendulum:initialAngle", angle)) {
                initialAngles.length = 0;
                lengths.length = 0;
                return;
            }
        }
        foreach (i, len; lengths) {
            if (!guardFinite(deformer, "pendulum:initialLength", len)) {
                initialAngles.length = 0;
                lengths.length = 0;
                return;
            }
        }
    }

    override
    void update() {
        if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) return;
        if (deformer.vertices.length < 2) return;
        if (!guardFinite(deformer, "pendulum:externalForce", externalForce)) {
            return;
        }
        // Automatically set timeStep similar to SimplePhysics
        float h = min(deltaTime(), 10); // Limit to 10 seconds max

        // Minimum physics timestep: 0.01s
        while (h > 0.01) {
            updatePendulum(angles, angularVelocities, lengths, damping, restoreConstant, 0.0, 0.01);
            if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) return;
            h -= 0.01;
        }

        updatePendulum(angles, angularVelocities, lengths, damping, restoreConstant, 0.0, h);
        if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) return;

        // Update deformation based on new angles
        auto newPositions = calculatePositions(base, angles, lengths);
        for (size_t i = 0; i < newPositions.length; i++) {
            vec2 physPos = newPositions[i];
            auto newPos = vec2(physPos.x, physicsToScreenY(physPos.y));
            if (!guardFinite(deformer, "pendulum:newPosition", newPos, i)) {
                physDeformation[i] = vec2(0, 0);
                continue;
            }
            auto delta = newPos - deformer.originalCurve.controlPoints[i];
            if (!guardFinite(deformer, "pendulum:newDelta", delta, i)) {
                physDeformation[i] = vec2(0, 0);
                continue;
            }
            physDeformation[i] = delta;
        }
        for (int i = 0; i < physDeformation.length; i++) {
            auto delta = physDeformation[i];
            if (!guardFinite(deformer, "pendulum:physDeformation", delta, i)) continue;
            deformer.deformation[i] += delta;
        }
    }

    override
    void serializeSelfImpl(ref InochiSerializer serializer) {
        serializer.putKey("type");
        serializer.serializeValue("Pendulum");
        serializer.putKey("damping");
        serializer.serializeValue(damping);
        serializer.putKey("restore_constant");
        serializer.serializeValue(restoreConstant);
        serializer.putKey("gravity");
        serializer.serializeValue(gravity);
        serializer.putKey("input_scale");
        serializer.serializeValue(inputScale);
        serializer.putKey("propagate_scale");
        serializer.serializeValue(propagateScale);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        if (data.isEmpty) return null;

        if (!data["damping"].isEmpty)
            if (auto exc = data["damping"].deserializeValue(this.damping)) return exc;
        if (!data["restore_constant"].isEmpty)
            if (auto exc = data["restore_constant"].deserializeValue(this.restoreConstant)) return exc;
        if (!data["gravity"].isEmpty)
            if (auto exc = data["gravity"].deserializeValue(this.gravity)) return exc;
        if (!data["input_scale"].isEmpty)
            if (auto exc = data["input_scale"].deserializeValue(this.inputScale)) return exc;
        if (!data["propagate_scale"].isEmpty)
            if (auto exc = data["propagate_scale"].deserializeValue(this.propagateScale)) return exc;

        return null;
    }

    override
    void copyFrom(PhysicsDriver src) {
        if (auto driver = cast(ConnectedPendulumDriver)src) {
            damping = driver.damping;
            restoreConstant = driver.restoreConstant;
            gravity = driver.gravity;
            inputScale = driver.inputScale;
            propagateScale = driver.propagateScale;
        }
    }

    private:
    auto extractAnglesAndLengths(Vec2Array controlPoints) {
        float[] angles;
        float[] lengths;
        bool degenerate = false;
        enum float lengthEpsilon = 1e-6f;
        for (int i = 1; i < controlPoints.length; i++) {
            auto vector = controlPoints[i] - controlPoints[i - 1];
            float angle = atan2(vector.x, -vector.y);
            float length = vector.length;
            angles ~= angle;
            lengths ~= length;
            if (!isFinite(length) || length <= lengthEpsilon) {
                writeln("[PhysicsPendulum][DegenerateSegment] node=",
                        deformer ? deformer.name : "<null>",
                        " segment=", i - 1, "->", i,
                        " length=", length,
                        " pointA=", controlPoints[i - 1],
                        " pointB=", controlPoints[i]);
                degenerate = true;
            }
        }
        if (degenerate && deformer !is null) {
            deformer.reportPhysicsDegeneracy("pendulum:degenerateSegment");
        }
        return tuple(angles, lengths);
    }

    Vec2Array calculatePositions(vec2 base, float[] angles, float[] lengths) {
        Vec2Array positions = Vec2Array([base]);
        float x = base.x;
        float y = base.y;
        for (int i = 0; i < angles.length; i++) {
            x += lengths[i] * sin(angles[i]);
            y -= lengths[i] * cos(angles[i]);
            positions ~= vec2(x, y);
        }
        return positions;
    }

    void updatePendulum(ref float[] currentAngles, ref float[] angularVelocities, float[] lengths, float damping, float restoreConstant, float v1Velocity, float timeStep) {
        if (lengths.length < 1)
            return;

        enum float lengthEpsilon = 1e-6f;
        float externalTorque = externalForce.x * timeStep * lengths[0]; // Simplified external torque calculation
        for (int i = 0; i < angles.length; i++) {
            if (!isFinite(lengths[i]) || lengths[i] <= lengthEpsilon) {
                writeln("[PhysicsPendulum][DegenerateUpdate] node=",
                        deformer ? deformer.name : "<null>",
                        " index=", i,
                        " restLength=", lengths[i]);
                if (deformer !is null) {
                    deformer.reportPhysicsDegeneracy("pendulum:zeroLength");
                }
                return;
            }
            float restoreTorque = -min(1 / timeStep, restoreConstant) * (currentAngles[i] - initialAngles[i]);
            float dampingTorque = -damping * angularVelocities[i];
            float baseVelocityEffect = v1Velocity / lengths[i] * cos(angles[i]);
            float gravitationalTorque = -gravity * sin(angles[i] + worldAngle);
            float angularAcceleration = restoreTorque + dampingTorque + baseVelocityEffect + gravitationalTorque + externalTorque;
            if (!isFinite(restoreTorque) || !isFinite(dampingTorque) || !isFinite(baseVelocityEffect) || !isFinite(gravitationalTorque) || !isFinite(angularAcceleration)) {
                if (deformer !is null) {
                    deformer.reportPhysicsDegeneracy("pendulum:torqueNaN");
                }
                return;
            }
            angularVelocities[i] += angularAcceleration * timeStep;
            if (!isFinite(angularVelocities[i])) {
                if (deformer !is null) {
                    deformer.reportPhysicsDegeneracy("pendulum:velocityNaN");
                }
                return;
            }
            currentAngles[i] += angularVelocities[i] * timeStep;
            if (!isFinite(currentAngles[i])) {
                if (deformer !is null) {
                    deformer.reportPhysicsDegeneracy("pendulum:angleNaN");
                }
                return;
            }
            externalTorque += (-angularAcceleration * sin(currentAngles[i])) * timeStep * lengths[i] * propagateScale;
            // Rotate x-y coordinates by worldAngle before finalizing
        }
    }
}

class ConnectedSpringPendulumDriver : PhysicsDriver {
    vec2 externalForce = vec2(0, 0); // External force vector

    override
    void retarget(PathDeformer deformer) {
        this.deformer = deformer;
        setup();
    }

    override
    void reset() {
        externalForce = vec2(0,0);
    }

    override
    void enforce(vec2 force) {
        if (!guardFinite(deformer, "springPendulum:enforceForce", force)) {
            return;
        }
        externalForce = force;
    }
    PathDeformer deformer;
    Vec2Array positions;
    Vec2Array velocities;
    Vec2Array initialPositions;  // store initial shape
    float[] lengths;
    Vec2Array physDeformation;
    float damping = 0.3;
    float springConstant = 10;
    float restorationConstant = 0.; // restoring force to initial shape
    float timeStep = 0.1;
    vec2 gravity = vec2(0, 9.8); // gravity

    this(PathDeformer deformer) {
        this.deformer = deformer;
    }
    
    override
    void setup() {
        updateDefaultShape();
        if (deformer is null) return;
        positions = initialPositions.dup;
        velocities.length = positions.length;
        velocities[] = vec2(0, 0);
        physDeformation.length = deformer.vertices.length;
        physDeformation[] = vec2(0, 0);
        lengths = new float[positions.length - 1];
        bool degenerate = false;
        enum float lengthEpsilon = 1e-6f;
        for (int i = 0; i < lengths.length; i++) {
            if (!guardFinite(deformer, "springPendulum:position", positions[i], i)) {
                degenerate = true;
                break;
            }
            if (!guardFinite(deformer, "springPendulum:position", positions[i + 1], i + 1)) {
                degenerate = true;
                break;
            }
            auto diff = positions[i + 1] - positions[i];
            float len = diff.length;
            lengths[i] = len;
            if (!isFinite(len) || len <= lengthEpsilon) {
                writeln("[PhysicsSpringPendulum][DegenerateSegment] node=",
                        deformer ? deformer.name : "<null>",
                        " segment=", i, "->", i + 1,
                        " length=", len,
                        " pointA=", positions[i],
                        " pointB=", positions[i + 1]);
                degenerate = true;
            }
        }
        if (degenerate && deformer !is null) {
            deformer.reportPhysicsDegeneracy("springPendulum:degenerateSegment");
            return;
        }
        if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) {
            return;
        }
    }

    override
    void updateDefaultShape() {
        auto originalPoints = deformer.originalCurve.controlPoints;
        initialPositions.length = originalPoints.length;
        foreach (i; 0 .. originalPoints.length) {
            vec2 pt = originalPoints[i];
            pt.y = screenToPhysicsY(pt.y);
            if (!guardFinite(deformer, "springPendulum:controlPoint", pt, i)) {
                initialPositions.length = 0;
                return;
            }
            initialPositions[i] = pt;
        }
        // Initial shape saved
    }

    override
    void update() {
        if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) return;
        // Automatically set timeStep similar to SimplePhysics
        float h = min(deltaTime(), 10); // Limit to 10 seconds max
        if (!guardFinite(deformer, "springPendulum:externalForce", externalForce)) {
            return;
        }

        while (h > 0.01) {
            updateSpringPendulum(positions, velocities, initialPositions, lengths, damping, springConstant, restorationConstant, 0.01);
            if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) return;
            h -= 0.01;
        }

        updateSpringPendulum(positions, velocities, initialPositions, lengths, damping, springConstant, restorationConstant, h);
        if (deformer is null || deformer.driver() !is cast(PhysicsDriver)this) return;

        for (int i = 0; i < positions.length; i++) {
            auto pos = positions[i];
            vec2 screenPos = vec2(pos.x, physicsToScreenY(pos.y));
            if (!screenPos.isFinite) {
                if (deformer !is null) {
                    deformer.reportDriverInvalid("springPendulum:position", i, screenPos);
                }
                physDeformation[i] = vec2(0, 0);
                continue;
            }
            auto delta = screenPos - deformer.originalCurve.controlPoints[i];
            if (!delta.isFinite) {
                if (deformer !is null) {
                    deformer.reportDriverInvalid("springPendulum:delta", i, delta);
                }
                physDeformation[i] = vec2(0, 0);
                continue;
            }
            physDeformation[i] = delta;
        }
        for (int i = 0; i < physDeformation.length; i++) {
            auto delta = physDeformation[i];
            if (!delta.isFinite) continue;
            deformer.deformation[i] += delta;
        }
    }

    override
    void rotate(float angle) { }

    override
    void serializeSelfImpl(ref InochiSerializer serializer) {
        serializer.putKey("type");
        serializer.serializeValue("SpringPendulum");

        // TBD
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        if (data.isEmpty) return null;

        // TBD

        return null;
    }

    override 
    void copyFrom(PhysicsDriver src) {
        // TBD
    }
    
private:
    void updateSpringPendulum(
        ref Vec2Array positions,
        ref Vec2Array velocities,
        Vec2Array initialPositions, // reference initial shape
        float[] lengths,
        float damping,
        float springConstant,
        float restorationConstant,
        float timeStep
    ) {

        enum float lengthEpsilon = 1e-6f;
        for (int i = 1; i < positions.length; i++) {
            vec2 springForce = vec2(0, 0);

            if (i > 0) {
                vec2 diff = positions[i] - ((i == 1)? positions[i - 1] + externalForce * timeStep: positions[i - 1]);
                if (!guardFinite(deformer, "springPendulum:diffPrev", diff, i)) {
                    return;
                }
                float diffLen = diff.length;
                if (!isFinite(diffLen) || diffLen <= lengthEpsilon) {
                    writeln("[PhysicsSpringPendulum][DegenerateUpdate] node=",
                            deformer ? deformer.name : "<null>",
                            " segment=", i - 1, "->", i,
                            " diffLen=", diffLen,
                            " restLen=", lengths[i - 1]);
                    if (deformer !is null) {
                        deformer.reportPhysicsDegeneracy("springPendulum:zeroDiff");
                    }
                    return;
                }
                springForce += -springConstant * (diff * (diffLen - lengths[i - 1]) / diffLen);
            }
            if (i < positions.length - 1) {
                vec2 diff = ((i == 0) ? positions[i] + externalForce * timeStep: positions[i]) - positions[i + 1];
                if (!guardFinite(deformer, "springPendulum:diffNext", diff, i)) {
                    return;
                }
                float diffLen = diff.length;
                if (!isFinite(diffLen) || diffLen <= lengthEpsilon) {
                    writeln("[PhysicsSpringPendulum][DegenerateUpdate] node=",
                            deformer ? deformer.name : "<null>",
                            " segment=", i, "->", i + 1,
                            " diffLen=", diffLen,
                            " restLen=", lengths[i]);
                    if (deformer !is null) {
                        deformer.reportPhysicsDegeneracy("springPendulum:zeroDiff");
                    }
                    return;
                }
                springForce += -springConstant * (diff * (diffLen - lengths[i]) / diffLen);
            }

            // restoring force to initial position
            vec2 restorationForce = -restorationConstant * (positions[i] - initialPositions[i]);

            vec2 dampingForce = -damping * velocities[i];
            vec2 acceleration = (springForce + dampingForce + restorationForce + gravity) / 1.0; // assume unit mass
            if (!guardFinite(deformer, "springPendulum:acceleration", acceleration, i)) {
                return;
            }
//        import std.stdio;
//        writefln("update: %s=%s, %s, %s, %s", acceleration, springForce, dampingForce, restorationForce, gravity);
            velocities[i] += acceleration * timeStep;
            if (!guardFinite(deformer, "springPendulum:velocity", velocities[i], i)) {
                return;
            }
            positions[i] += velocities[i] * timeStep;
            if (!guardFinite(deformer, "springPendulum:positionUpdate", positions[i], i)) {
                return;
            }
        }
    }
}
