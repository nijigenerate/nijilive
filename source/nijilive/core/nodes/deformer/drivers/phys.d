module nijilive.core.nodes.deformer.drivers.phys;

import nijilive.core.nodes.deformer.bezier;
import nijilive.math;
import std.math;
import std.typecons : tuple; // Import for tuple
import nijilive; // Import for deltaTime
import std.algorithm;
import std.array;

interface PhysicsDriver {
    void setup();
    void reset();
    void enforce(vec2 force);
    void rotate(float angle);
    void update();
    void updateDefaultShape();
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
        worldAngle = angle;
    }

    override
    void enforce(vec2 force) {
        externalForce = force * inputScale;
    }
    BezierDeformer deformer;
    float[] angles;
    float[] initialAngles;
    float[] angularVelocities;
    float[] lengths;
    vec2[] physDeformation;
    float damping = 1.0;
    float restoreConstant = 300;
    float timeStep = 0.01;
    float gravity = 9.8; // Gravitational acceleration
    float inputScale = 0.01;
    float propagateScale = 0.2;
    vec2 base;

    this(BezierDeformer deformer) {
        this.deformer = deformer;
    }

    override
    void setup() {
        if (deformer.vertices.length < 2) return;
        // Initialize angles and lengths based on original control points
        updateDefaultShape();
        angles = initialAngles.dup;
        angularVelocities = new float[angles.length];
        foreach (i; 0..angularVelocities.length) {
            angularVelocities[i] = 0;
        }
        physDeformation = new vec2[deformer.vertices.length];
        foreach (i; 0..physDeformation.length) {
            physDeformation[i] = vec2(0, 0);
        }
        base = vec2(deformer.originalCurve.controlPoints[0].x, screenToPhysicsY(deformer.originalCurve.controlPoints[0].y));
    }

    override
    void updateDefaultShape() {
        vec2[] physicsControlPoints;
        foreach (i, p; deformer.originalCurve.controlPoints) {
            physicsControlPoints ~= vec2(p.x, screenToPhysicsY(p.y));
        }
        auto initialAnglesAndLengths = extractAnglesAndLengths(physicsControlPoints);
        initialAngles = initialAnglesAndLengths[0];
        lengths = initialAnglesAndLengths[1];
    }

    override
    void update() {
        if (deformer is null || deformer.vertices.length < 2) return;
        // Automatically set timeStep similar to SimplePhysics
        float h = min(deltaTime(), 10); // Limit to 10 seconds max

        // Minimum physics timestep: 0.01s
        while (h > 0.01) {
            updatePendulum(angles, angularVelocities, lengths, damping, restoreConstant, 0.0, 0.01);
            h -= 0.01;
        }

        updatePendulum(angles, angularVelocities, lengths, damping, restoreConstant, 0.0, h);

        // Update deformation based on new angles
        auto newPositions = calculatePositions(base, angles, lengths).map!(p => vec2(p.x, physicsToScreenY(p.y)));
        for (int i = 0; i < newPositions.length; i++) {
            physDeformation[i] = newPositions[i] - deformer.originalCurve.controlPoints[i];
        }
        for (int i = 0; i < physDeformation.length; i++) {
            deformer.deformation[i] += physDeformation[i];
        }
    }

    private:
    auto extractAnglesAndLengths(vec2[] controlPoints) {
        float[] angles;
        float[] lengths;
        for (int i = 1; i < controlPoints.length; i++) {
            auto vector = controlPoints[i] - controlPoints[i - 1];
            float angle = atan2(vector.x, -vector.y);
            float length = vector.length;
            angles ~= angle;
            lengths ~= length;
        }
        return tuple(angles, lengths);
    }

    vec2[] calculatePositions(vec2 base, float[] angles, float[] lengths) {
        vec2[] positions = [base];
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

        float externalTorque = externalForce.x * timeStep * lengths[0]; // Simplified external torque calculation
        for (int i = 0; i < angles.length; i++) {
            float restoreTorque = -min(1 / timeStep, restoreConstant) * (currentAngles[i] - initialAngles[i]);
            float dampingTorque = -damping * angularVelocities[i];
            float baseVelocityEffect = v1Velocity / lengths[i] * cos(angles[i]);
            float gravitationalTorque = -gravity * sin(angles[i] + worldAngle);
            float angularAcceleration = restoreTorque + dampingTorque + baseVelocityEffect + gravitationalTorque + externalTorque;
            angularVelocities[i] += angularAcceleration * timeStep;
            currentAngles[i] += angularVelocities[i] * timeStep;
            externalTorque += (-angularAcceleration * sin(currentAngles[i])) * timeStep * lengths[i] * propagateScale;
            // Rotate x-y coordinates by worldAngle before finalizing
        }
    }
}

class ConnectedSpringPendulumDriver : PhysicsDriver {
    vec2 externalForce = vec2(0, 0); // External force vector

    override
    void reset() {
        externalForce = vec2(0,0);
    }

    override
    void enforce(vec2 force) {
        externalForce = force;
    }
    BezierDeformer deformer;
    vec2[] positions;
    vec2[] velocities;
    vec2[] initialPositions;  // 初期形状を保存
    float[] lengths;
    vec2[] physDeformation;
    float damping = 0.3;
    float springConstant = 10;
    float restorationConstant = 0.; // 初期形状への復元力
    float timeStep = 0.1;
    vec2 gravity = vec2(0, 9.8); // 重力

    this(BezierDeformer deformer) {
        this.deformer = deformer;
    }
    
    override
    void setup() {
        updateDefaultShape();
        positions = initialPositions.dup;
        velocities = new vec2[positions.length];
        foreach (i; 0..velocities.length) {
            velocities[i] = vec2(0, 0);
        }
        physDeformation = new vec2[deformer.vertices.length];
        lengths = new float[positions.length - 1];
        for (int i = 0; i < lengths.length; i++) {
            lengths[i] = (positions[i + 1] - positions[i]).length;
        }
    }

    override
    void updateDefaultShape() {
        auto physicsControlPoints = deformer.originalCurve.controlPoints.map!(p => vec2(p.x, screenToPhysicsY(p.y))).array;
        initialPositions = physicsControlPoints.dup; // 初期形状を保存
    }

    override
    void update() {
        // Automatically set timeStep similar to SimplePhysics
        float h = min(deltaTime(), 10); // Limit to 10 seconds max

        while (h > 0.01) {
            updateSpringPendulum(positions, velocities, initialPositions, lengths, damping, springConstant, restorationConstant, 0.01);
            h -= 0.01;
        }

        updateSpringPendulum(positions, velocities, initialPositions, lengths, damping, springConstant, restorationConstant, h);

        for (int i = 0; i < positions.length; i++) {
            physDeformation[i] = vec2(positions[i].x, physicsToScreenY(positions[i].y)) - deformer.originalCurve.controlPoints[i];
        }
        for (int i = 0; i < physDeformation.length; i++) {
            deformer.deformation[i] += physDeformation[i];
        }
    }

    override
    void rotate(float angle) { }

private:
    void updateSpringPendulum(
        ref vec2[] positions,
        ref vec2[] velocities,
        vec2[] initialPositions, // 初期形状を参照
        float[] lengths,
        float damping,
        float springConstant,
        float restorationConstant,
        float timeStep
    ) {

        for (int i = 1; i < positions.length; i++) {
            vec2 springForce = vec2(0, 0);

            if (i > 0) {
                vec2 diff = positions[i] - ((i == 1)? positions[i - 1] + externalForce * timeStep: positions[i - 1]);
                springForce += -springConstant * (diff * (diff.length - lengths[i - 1]) / diff.length);
            }
            if (i < positions.length - 1) {
                vec2 diff = ((i == 0) ? positions[i] + externalForce * timeStep: positions[i]) - positions[i + 1];
                springForce += -springConstant * (diff * (diff.length - lengths[i]) / diff.length);
            }

            // 初期位置への復元力
            vec2 restorationForce = -restorationConstant * (positions[i] - initialPositions[i]);

            vec2 dampingForce = -damping * velocities[i];
            vec2 acceleration = (springForce + dampingForce + restorationForce + gravity) / 1.0; // 質量1と仮定
        import std.stdio;
        writefln("update: %s=%s, %s, %s, %s", acceleration, springForce, dampingForce, restorationForce, gravity);
            velocities[i] += acceleration * timeStep;
            positions[i] += velocities[i] * timeStep;
        }
    }
}
