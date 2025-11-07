/*
    nijilive Simple Physics Node
    previously Inochi2D Simple Physics Node

    Copyright © 2022, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.

    Authors: Asahi Lina
*/
module nijilive.core.nodes.drivers.simplephysics;
private {
import nijilive.core.nodes.drivers;
import nijilive.core.nodes.common;
//import nijilive.core.nodes;
import nijilive.fmt;
import nijilive.core.dbg;
//import nijilive.core;
import nijilive.math;
import std.conv : text;
import std.math : isFinite, isNaN, fabs;
import std.stdio : writeln;
import nijilive.phys;
import nijilive;
import std.exception;
import std.algorithm.sorting;
//import std.stdio;
}

private bool isFiniteVec(vec2 value) {
    return isFinite(value.x) && isFinite(value.y);
}

/**
    Physics model to use for simple physics
*/
enum PhysicsModel {
    /**
        Rigid pendulum
    */
    Pendulum = "pendulum",

    /**
        Springy pendulum
    */
    SpringPendulum = "spring_pendulum",
}

enum ParamMapMode {
    AngleLength = "angle_length",
    XY = "xy",
    LengthAngle = "length_angle",
    YX = "yx",
}

class Pendulum : PhysicsSystem {
    SimplePhysics driver;

private:
    vec2 bob = vec2(0, 0);
    float angle = 0;
    float dAngle = 0;

protected:
    override
    void eval(float t) {
        setD(angle, dAngle);
        float gravityVal = driver.getGravity();
        float lengthVal = driver.getLength();
        if (!isFinite(gravityVal) || !isFinite(lengthVal) || fabs(lengthVal) <= float.epsilon) {
            driver.logPhysicsState("Pendulum:invalidParams",
                text("gravity=", gravityVal,
                     " length=", lengthVal));
            setD(dAngle, 0);
            return;
        }

        float lengthRatio = gravityVal / lengthVal;
        if (!isFinite(lengthRatio) || lengthRatio < 0) {
            driver.logPhysicsState("Pendulum:lengthRatioInvalid",
                text("gravity=", gravityVal,
                     " length=", lengthVal,
                     " lengthRatio=", lengthRatio));
            setD(dAngle, 0);
            return;
        }

        float critDamp = 2 * sqrt(lengthRatio);
        if (!isFinite(critDamp)) {
            driver.logPhysicsState("Pendulum:critDampInvalid",
                text("lengthRatio=", lengthRatio,
                     " critDamp=", critDamp));
            setD(dAngle, 0);
            return;
        }

        float angleDampingVal = driver.getAngleDamping();
        if (!isFinite(angleDampingVal)) {
            driver.logPhysicsState("Pendulum:angleDampingInvalid",
                text("angleDamping=", angleDampingVal));
            setD(dAngle, 0);
            return;
        }

        float dd = -lengthRatio * sin(angle);
        if (!isFinite(dd)) {
            driver.logPhysicsState("Pendulum:ddInitialInvalid",
                text("lengthRatio=", lengthRatio,
                     " angle=", angle,
                     " dd=", dd));
            dd = 0;
        }
        dd -= dAngle * angleDampingVal * critDamp;
        if (!isFinite(dd)) {
            driver.logPhysicsState("Pendulum:ddDampedInvalid",
                text("dAngle=", dAngle,
                     " angleDamping=", angleDampingVal,
                     " critDamp=", critDamp,
                     " dd=", dd));
            dd = 0;
        }
        setD(dAngle, dd);
    }

public:

    this(SimplePhysics driver) {
        this.driver = driver;

        bob = driver.anchor + vec2(0, driver.getLength());

        addVariable(&angle);
        addVariable(&dAngle);
    }

    override
    void tick(float h) {
        // Compute the angle against the updated anchor position
        vec2 dBob = bob - driver.anchor;
        if (!isFiniteVec(dBob)) {
            driver.logPhysicsState("Pendulum:dBobNonFinite",
                text("bob=", bob,
                     " anchor=", driver.anchor,
                     " dBob=", dBob));
            return;
        }
        angle = atan2(-dBob.x, dBob.y);
        if (!isFinite(angle)) {
            driver.logPhysicsState("Pendulum:angleNonFinite",
                text("dBob=", dBob,
                     " angle=", angle));
            return;
        }

        // Run the pendulum simulation in terms of angle
        super.tick(h);
        if (!isFinite(angle) || !isFinite(dAngle)) {
            driver.logPhysicsState("Pendulum:stateAfterTickNonFinite",
                text("angle=", angle,
                     " dAngle=", dAngle,
                     " step=", h));
            return;
        }

        // Update the bob position at the new angle
        dBob = vec2(-sin(angle), cos(angle));
        if (!isFiniteVec(dBob)) {
            driver.logPhysicsState("Pendulum:unitVectorNonFinite",
                text("angle=", angle,
                     " dBob=", dBob));
            return;
        }
        float lengthVal = driver.getLength();
        if (!isFinite(lengthVal) || fabs(lengthVal) <= float.epsilon) {
            driver.logPhysicsState("Pendulum:lengthInvalidInTick",
                text("length=", lengthVal));
            return;
        }
        bob = driver.anchor + dBob * lengthVal;
        if (!isFiniteVec(bob)) {
            driver.logPhysicsState("Pendulum:bobNonFinite",
                text("anchor=", driver.anchor,
                     " dBob=", dBob,
                     " length=", lengthVal,
                     " bob=", bob));
            return;
        }

        driver.output = bob;
    }

    override
    void drawDebug(mat4 trans = mat4.identity) {
        vec3[] points = [
            vec3(driver.anchor.x, driver.anchor.y, 0),
            vec3(bob.x, bob.y, 0),
        ];

        inDbgSetBuffer(points);
        inDbgLineWidth(3);
        inDbgDrawLines(vec4(1, 0, 1, 1), trans);
    }

    override
    void updateAnchor() {
        bob = driver.anchor + vec2(0, driver.getLength());
    }
}

class SpringPendulum : PhysicsSystem {
    SimplePhysics driver;

private:
    vec2 bob = vec2(0, 0);
    vec2 dBob = vec2(0, 0);

protected:
    override
    void eval(float t) {
        setD(bob, dBob);

        // These are normalized vs. mass
        float frequencyVal = driver.getFrequency();
        if (!isFinite(frequencyVal) || fabs(frequencyVal) <= float.epsilon) {
            driver.logPhysicsState("SpringPendulum:frequencyInvalid",
                text("frequency=", frequencyVal));
            setD(dBob, vec2(0, 0));
            return;
        }

        float springKsqrt = frequencyVal * 2 * PI;
        if (!isFinite(springKsqrt)) {
            driver.logPhysicsState("SpringPendulum:springKsqrtInvalid",
                text("springKsqrt=", springKsqrt,
                     " frequency=", frequencyVal));
            setD(dBob, vec2(0, 0));
            return;
        }

        float springK = springKsqrt ^^ 2;
        if (!isFinite(springK) || fabs(springK) <= float.epsilon) {
            driver.logPhysicsState("SpringPendulum:springKInvalid",
                text("springK=", springK,
                     " springKsqrt=", springKsqrt));
            setD(dBob, vec2(0, 0));
            return;
        }

        float g = driver.getGravity();
        if (!isFinite(g)) {
            driver.logPhysicsState("SpringPendulum:gravityInvalid",
                text("gravity=", g));
            setD(dBob, vec2(0, 0));
            return;
        }

        float lengthVal = driver.getLength();
        if (!isFinite(lengthVal) || fabs(lengthVal) <= float.epsilon) {
            driver.logPhysicsState("SpringPendulum:lengthInvalid",
                text("length=", lengthVal));
            setD(dBob, vec2(0, 0));
            return;
        }

        float restLength = lengthVal - g / springK;
        if (!isFinite(restLength)) {
            driver.logPhysicsState("SpringPendulum:restLengthInvalid",
                text("length=", lengthVal,
                     " gravity=", g,
                     " springK=", springK,
                     " restLength=", restLength));
            setD(dBob, vec2(0, 0));
            return;
        }

        vec2 offPos = bob - driver.anchor;
        if (!isFiniteVec(offPos)) {
            driver.logPhysicsState("SpringPendulum:offPosNonFinite",
                text("bob=", bob,
                     " anchor=", driver.anchor,
                     " offPos=", offPos));
            setD(dBob, vec2(0, 0));
            return;
        }
        vec2 offPosNorm = offPos.normalized;
        if (!isFiniteVec(offPosNorm)) {
            driver.logPhysicsState("SpringPendulum:offPosNormNonFinite",
                text("offPos=", offPos,
                     " offPosNorm=", offPosNorm));
            setD(dBob, vec2(0, 0));
            return;
        }

        float lengthRatio = g / lengthVal;
        if (!isFinite(lengthRatio) || lengthRatio < 0) {
            driver.logPhysicsState("SpringPendulum:lengthRatioInvalid",
                text("gravity=", g,
                     " length=", lengthVal,
                     " lengthRatio=", lengthRatio));
            setD(dBob, vec2(0, 0));
            return;
        }

        float critDampAngle = 2 * sqrt(lengthRatio);
        float critDampLength = 2 * springKsqrt;
        if (!isFinite(critDampAngle) || !isFinite(critDampLength)) {
            driver.logPhysicsState("SpringPendulum:critDampInvalid",
                text("critDampAngle=", critDampAngle,
                     " critDampLength=", critDampLength,
                     " lengthRatio=", lengthRatio,
                     " springKsqrt=", springKsqrt));
            setD(dBob, vec2(0, 0));
            return;
        }

        float dist = abs(driver.anchor.distance(bob));
        if (!isFinite(dist)) {
            driver.logPhysicsState("SpringPendulum:distanceInvalid",
                text("anchor=", driver.anchor,
                     " bob=", bob,
                     " dist=", dist));
            setD(dBob, vec2(0, 0));
            return;
        }
        vec2 force = vec2(0, g);
        force -= offPosNorm * (dist - restLength) * springK;
        vec2 ddBob = force;
        if (!isFiniteVec(ddBob)) {
            vec2 invalidForce = ddBob;
            driver.logPhysicsState("SpringPendulum:ddBobInvalid",
                text("force=", invalidForce,
                     " offPosNorm=", offPosNorm,
                     " dist=", dist,
                     " restLength=", restLength,
                     " springK=", springK));
            ddBob = vec2(0, 0);
        }

        vec2 dBobRot = vec2(
            dBob.x * offPosNorm.y + dBob.y * offPosNorm.x,
            dBob.y * offPosNorm.y - dBob.x * offPosNorm.x,
        );

        float angleDampingVal = driver.getAngleDamping();
        float lengthDampingVal = driver.getLengthDamping();
        if (!isFinite(angleDampingVal) || !isFinite(lengthDampingVal)) {
            driver.logPhysicsState("SpringPendulum:dampingInvalid",
                text("angleDamping=", angleDampingVal,
                     " lengthDamping=", lengthDampingVal));
            setD(dBob, vec2(0, 0));
            return;
        }

        vec2 ddBobRot = -vec2(
            dBobRot.x * angleDampingVal * critDampAngle,
            dBobRot.y * lengthDampingVal * critDampLength,
        );
        if (!isFiniteVec(ddBobRot)) {
            vec2 invalidDdBobRot = ddBobRot;
            driver.logPhysicsState("SpringPendulum:ddBobRotInvalid",
                text("dBobRot=", dBobRot,
                     " angleDamping=", angleDampingVal,
                     " lengthDamping=", lengthDampingVal,
                     " critDampAngle=", critDampAngle,
                     " critDampLength=", critDampLength,
                     " ddBobRot=", invalidDdBobRot));
            ddBobRot = vec2(0, 0);
        }

        vec2 ddBobDamping = vec2(
            ddBobRot.x * offPosNorm.y - dBobRot.y * offPosNorm.x,
            ddBobRot.y * offPosNorm.y + dBobRot.x * offPosNorm.x,
        );
        if (!isFiniteVec(ddBobDamping)) {
            vec2 invalidDdBobDamping = ddBobDamping;
            driver.logPhysicsState("SpringPendulum:ddBobDampingInvalid",
                text("ddBobRot=", ddBobRot,
                     " dBobRot=", dBobRot,
                     " offPosNorm=", offPosNorm,
                     " ddBobDamping=", invalidDdBobDamping));
            ddBobDamping = vec2(0, 0);
        }

        ddBob += ddBobDamping;
        if (!isFiniteVec(ddBob)) {
            vec2 invalidDdBob = ddBob;
            driver.logPhysicsState("SpringPendulum:ddBobAfterDampingInvalid",
                text("ddBob=", invalidDdBob));
            ddBob = vec2(0, 0);
        }

        setD(dBob, ddBob);
    }

public:

    this(SimplePhysics driver) {
        this.driver = driver;

        bob = driver.anchor + vec2(0, driver.getLength());

        addVariable(&bob);
        addVariable(&dBob);
    }

    override
    void tick(float h) {
        // Run the spring pendulum simulation
        super.tick(h);

        if (!isFiniteVec(bob) || !isFiniteVec(dBob)) {
            driver.logPhysicsState("SpringPendulum:stateAfterTickNonFinite",
                text("bob=", bob,
                     " dBob=", dBob,
                     " step=", h));
            return;
        }

        if (!isFiniteVec(driver.anchor)) {
            driver.logPhysicsState("SpringPendulum:anchorNonFinite",
                text("anchor=", driver.anchor));
            return;
        }

        driver.output = bob;
    }

    override
    void drawDebug(mat4 trans = mat4.identity) {
        vec3[] points = [
            vec3(driver.anchor.x, driver.anchor.y, 0),
            vec3(bob.x, bob.y, 0),
        ];

        inDbgSetBuffer(points);
        inDbgLineWidth(3);
        inDbgDrawLines(vec4(1, 0, 1, 1), trans);
    }

    override
    void updateAnchor() {
        bob = driver.anchor + vec2(0, driver.getLength());
    }
}

/**
    Simple Physics Node
*/
@TypeId("SimplePhysics")
class SimplePhysics : Driver {
private:
    this() { }

    @Name("param")
    uint paramRef = InInvalidUUID;

    @Ignore
    Parameter param_;

    @Ignore
    float offsetGravity = 1.0;

    @Ignore
    float offsetLength = 0;

    @Ignore
    float offsetFrequency = 1;

    @Ignore
    float offsetAngleDamping = 0.5;

    @Ignore
    float offsetLengthDamping = 0.5;

    @Ignore
    vec2 offsetOutputScale = vec2(1, 1);

    enum float FlipDiagClusterTolerance = 5.0f;
    enum size_t FlipDiagLogStart = 4;
    enum size_t FlipDiagLogRepeat = 32;

    struct FlipCluster {
        vec2 min;
        vec2 max;
        vec2 reference;
        bool initialized;

        void reset(vec2 value) {
            min = value;
            max = value;
            reference = value;
            initialized = true;
        }

        void include(vec2 value) {
            if (!initialized) {
                reset(value);
                return;
            }
            if (value.x < min.x) min.x = value.x;
            if (value.x > max.x) max.x = value.x;
            if (value.y < min.y) min.y = value.y;
            if (value.y > max.y) max.y = value.y;
            reference = value;
        }

        float distanceTo(vec2 value) const {
            if (!initialized) {
                return float.infinity;
            }
            return reference.distance(value);
        }

        string valueSummary() const {
            if (!initialized) return "[]";
            return text("[", reference.x, ", ", reference.y, "]");
        }

        string rangeSummary() const {
            if (!initialized) return "[[nan, nan] .. [nan, nan]]";
            return text("[[", min.x, ", ", min.y, "] .. [", max.x, ", ", max.y, "]]");
        }
    }

    struct FlipDetector2D {
        FlipCluster clusterA;
        FlipCluster clusterB;
        bool lastIsA = true;
        bool stateInitialized = false;
        size_t toggleCount = 0;

        void reset() {
            clusterA = FlipCluster.init;
            clusterB = FlipCluster.init;
            lastIsA = true;
            stateInitialized = false;
            toggleCount = 0;
        }
    }

    FlipDetector2D outputFlipDiag;
    FlipDetector2D anchorFlipDiag;

protected:
    override
    string typeId() { return "SimplePhysics"; }

    /**
        Allows serializing self data (with pretty serializer)
    */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive=true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);
        serializer.putKey("param");
        serializer.serializeValue(paramRef);
        serializer.putKey("model_type");
        serializer.serializeValue(modelType_);
        serializer.putKey("map_mode");
        serializer.serializeValue(mapMode);
        serializer.putKey("gravity");
        serializer.serializeValue(gravity);
        serializer.putKey("length");
        serializer.serializeValue(length);
        serializer.putKey("frequency");
        serializer.serializeValue(frequency);
        serializer.putKey("angle_damping");
        serializer.serializeValue(angleDamping);
        serializer.putKey("length_damping");
        serializer.serializeValue(lengthDamping);
        serializer.putKey("output_scale");
        outputScale.serialize(serializer);
        serializer.putKey("local_only");
        serializer.serializeValue(localOnly);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        super.deserializeFromFghj(data);

        if (!data["param"].isEmpty)
            if (auto exc = data["param"].deserializeValue(this.paramRef)) return exc;
        if (!data["model_type"].isEmpty)
            if (auto exc = data["model_type"].deserializeValue(this.modelType_)) return exc;
        if (!data["map_mode"].isEmpty)
            if (auto exc = data["map_mode"].deserializeValue(this.mapMode)) return exc;
        if (!data["gravity"].isEmpty)
            if (auto exc = data["gravity"].deserializeValue(this.gravity)) return exc;
        if (!data["length"].isEmpty)
            if (auto exc = data["length"].deserializeValue(this.length)) return exc;
        if (!data["frequency"].isEmpty)
            if (auto exc = data["frequency"].deserializeValue(this.frequency)) return exc;
        if (!data["angle_damping"].isEmpty)
            if (auto exc = data["angle_damping"].deserializeValue(this.angleDamping)) return exc;
        if (!data["length_damping"].isEmpty)
            if (auto exc = data["length_damping"].deserializeValue(this.lengthDamping)) return exc;
        if (!data["output_scale"].isEmpty)
            if (auto exc = outputScale.deserialize(data["output_scale"])) return exc;
        if (!data["local_only"].isEmpty)
            if (auto exc = data["local_only"].deserializeValue(this.localOnly)) return exc;

        return null;
    }

public:
    PhysicsModel modelType_ = PhysicsModel.Pendulum;
    ParamMapMode mapMode = ParamMapMode.AngleLength;

    /**
        Whether physics system listens to local transform only.
    */
    bool localOnly = false;

    /**
        Gravity scale (1.0 = puppet gravity)
    */
    float gravity = 1.0;

    /**
        Pendulum/spring rest length (pixels)
    */
    float length = 100;

    /**
        Resonant frequency (Hz)
    */
    float frequency = 1;

    /**
        Angular damping ratio
    */
    float angleDamping = 0.5;

    /**
        Length damping ratio
    */
    float lengthDamping = 0.5;
    vec2 outputScale = vec2(1, 1);

    @Ignore
    vec2 prevAnchor = vec2(0, 0);
    @Ignore
    mat4 prevTransMat;
    @Ignore
    bool prevAnchorSet = false;

    @Ignore
    vec2 anchor = vec2(0, 0);

    @Ignore
    vec2 output;

    @Ignore
    PhysicsSystem system;

    /**
        Constructs a new SimplePhysics node
    */
    this(Node parent = null) {
        this(inCreateUUID(), parent);
    }

    /**
        Constructs a new SimplePhysics node
    */
    this(uint uuid, Node parent = null) {
        super(uuid, parent);
        reset();
    }

    override
    protected void runBeginTask() {
        super.runBeginTask();
        offsetGravity = 1;
        offsetLength = 0;
        offsetFrequency = 1;
        offsetAngleDamping = 1;
        offsetLengthDamping = 1;
        offsetOutputScale = vec2(1, 1);
    }

    override
    Parameter[] getAffectedParameters() {
        if (param_ is null) return [];
        return [param_];
    }

    override
    void updateDriver() {
        
        // Timestep is limited to 10 seconds, as if you
        // Are getting 0.1 FPS, you have bigger issues to deal with.
        float h = min(deltaTime(), 10);

        updateInputs();

        // Minimum physics timestep: 0.01s
        while (h > 0.01) {
            system.tick(0.01);
            h -= 0.01;
        }

        system.tick(h);
        updateOutputs();
        prevAnchorSet = false;
    }

    void updateAnchors() {
        system.updateAnchor();
    }

    private string physicsLogPrefix(string context) {
        return text("[SimplePhysics][", context, "] node=", name, " uuid=", uuid(), " ");
    }

    private string physicsStateSummary() {
        string systemName = system is null ? "null" : system.classinfo.name;
        auto puppetRef = puppet;
        float puppetGravityValue = float.nan;
        float puppetScaleValue = float.nan;
        if (puppetRef !is null && puppetRef.physics !is null) {
            puppetGravityValue = puppetRef.physics.gravity;
            puppetScaleValue = puppetRef.physics.pixelsPerMeter;
        }
        return text("system=", systemName,
                    " output=", output,
                    " anchor=", anchor,
                    " prevAnchorSet=", prevAnchorSet,
                    " localOnly=", localOnly,
                    " gravity=", getGravity(),
                    " length=", getLength(),
                    " frequency=", getFrequency(),
                    " angleDamping=", getAngleDamping(),
                    " lengthDamping=", getLengthDamping(),
                    " outputScale=", getOutputScale(),
                    " offsetGravity=", offsetGravity,
                    " offsetLength=", offsetLength,
                    " offsetFrequency=", offsetFrequency,
                    " offsetAngleDamping=", offsetAngleDamping,
                    " offsetLengthDamping=", offsetLengthDamping,
                    " offsetOutputScale=", offsetOutputScale,
                    " puppetGravity=", puppetGravityValue,
                    " puppetPixelsPerMeter=", puppetScaleValue,
                    " prevTransMat=", prevTransMat);
    }

    private void logPhysicsState(string context, string extra = "") {
        auto baseInfo = physicsStateSummary();
        if (extra.length) {
            writeln(physicsLogPrefix(context), baseInfo, " ", extra);
        } else {
            writeln(physicsLogPrefix(context), baseInfo);
        }
    }

    void trackFlipState(string label, ref FlipDetector2D detector, vec2 value) {
        if (!isFinite(value.x) || !isFinite(value.y)) return;

        bool matchesA = detector.clusterA.initialized &&
                        detector.clusterA.distanceTo(value) <= FlipDiagClusterTolerance;
        bool matchesB = detector.clusterB.initialized &&
                        detector.clusterB.distanceTo(value) <= FlipDiagClusterTolerance;

        if (!matchesA && !matchesB) {
            if (!detector.clusterA.initialized) {
                detector.clusterA.reset(value);
                detector.lastIsA = true;
                detector.stateInitialized = false;
                detector.toggleCount = 0;
                return;
            }
            if (!detector.clusterB.initialized) {
                detector.clusterB.reset(value);
                detector.lastIsA = false;
                detector.stateInitialized = detector.clusterA.initialized && detector.clusterB.initialized;
                detector.toggleCount = 0;
                return;
            }
            detector.clusterA.reset(value);
            detector.clusterB = FlipCluster.init;
            detector.lastIsA = true;
            detector.stateInitialized = false;
            detector.toggleCount = 0;
            return;
        }

        bool currentIsA;
        if (matchesA && (!matchesB || detector.clusterA.distanceTo(value) <= detector.clusterB.distanceTo(value))) {
            detector.clusterA.include(value);
            currentIsA = true;
        } else {
            detector.clusterB.include(value);
            currentIsA = false;
        }

        bool emitLog = false;
        if (detector.stateInitialized) {
            if (currentIsA != detector.lastIsA) {
                detector.toggleCount++;
                size_t toggles = detector.toggleCount;
                if (toggles >= FlipDiagLogStart &&
                    (toggles == FlipDiagLogStart ||
                     ((toggles - FlipDiagLogStart) % FlipDiagLogRepeat == 0))) {
                    emitLog = detector.clusterA.initialized && detector.clusterB.initialized;
                }
            }
        } else if (detector.clusterA.initialized && detector.clusterB.initialized) {
            detector.stateInitialized = true;
            detector.toggleCount = 0;
        }

        detector.lastIsA = currentIsA;
        if (!detector.stateInitialized && detector.clusterA.initialized && detector.clusterB.initialized) {
            detector.stateInitialized = true;
            detector.toggleCount = 0;
        }

        if (emitLog) {
            float distance = detector.clusterA.reference.distance(detector.clusterB.reference);
            logPhysicsState("flipDiag:" ~ label,
                text("toggles=", detector.toggleCount,
                     " valueA=", detector.clusterA.valueSummary(),
                     " valueB=", detector.clusterB.valueSummary(),
                     " rangeA=", detector.clusterA.rangeSummary(),
                     " rangeB=", detector.clusterB.rangeSummary(),
                     " distance=", distance));
        }
    }

    void updateInputs() {
        if (prevAnchorSet) {
        } else {
            auto anchorPos = localOnly ? 
                (vec4(transformLocal.translation, 1)) : 
                (transform.matrix * vec4(0, 0, 0, 1));
            if (!isFinite(anchorPos.x) || !isFinite(anchorPos.y)) {
                logPhysicsState("updateInputs:anchorNonFinite",
                    text("anchorPos=", anchorPos,
                         " localOnly=", localOnly,
                         " transformLocal.translation=", transformLocal.translation,
                         " transform.matrix=", transform.matrix));
                return;
            }
            anchor = vec2(anchorPos.x, anchorPos.y);
        }
    }

    override
    void preProcess() {
        auto prevPos = (localOnly ? 
            (vec4(transformLocal.translation, 1)) : 
            (transform.matrix * vec4(0, 0, 0, 1))).xy;
        super.preProcess(); 
        auto anchorPos = (localOnly ? 
            (vec4(transformLocal.translation, 1)) : 
            (transform.matrix * vec4(0, 0, 0, 1))).xy;
        if (!isFinite(anchorPos.x) || !isFinite(anchorPos.y)) {
            logPhysicsState("preProcess:anchorNonFinite",
                text("anchorPos=", anchorPos,
                     " transformLocal.translation=", transformLocal.translation,
                     " transform.matrix=", transform.matrix));
            return;
        }
        if (anchorPos != prevPos) {
            anchor = anchorPos;
            prevTransMat = transform.matrix.inverse;
            prevAnchorSet = true;
        }
    }

    override
    void postProcess(int id = 0) { 
        auto prevPos = (localOnly ? 
            (vec4(transformLocal.translation, 1)) : 
            (transform.matrix * vec4(0, 0, 0, 1))).xy;
        super.postProcess(id); 
        auto anchorPos = (localOnly ? 
            (vec4(transformLocal.translation, 1)) : 
            (transform.matrix * vec4(0, 0, 0, 1))).xy;
        if (!isFinite(anchorPos.x) || !isFinite(anchorPos.y)) {
            logPhysicsState("postProcess:anchorNonFinite",
                text("anchorPos=", anchorPos,
                     " transformLocal.translation=", transformLocal.translation,
                     " transform.matrix=", transform.matrix));
            return;
        }
        if (anchorPos != prevPos) {
            anchor = anchorPos;
            prevTransMat = transform.matrix.inverse;
            prevAnchorSet = true;
        }
    }

    void updateOutputs() {
        if (param is null) return;

        if (!isFinite(output.x) || !isFinite(output.y)) {
            logPhysicsState("updateOutputs:outputNonFinite");
            return;
        }
        if (!isFinite(anchor.x) || !isFinite(anchor.y)) {
            logPhysicsState("updateOutputs:anchorNonFinite");
            return;
        }

        trackFlipState("output", outputFlipDiag, output);
        trackFlipState("anchor", anchorFlipDiag, anchor);

        vec2 oscale = getOutputScale();
        if (!isFinite(oscale.x) || !isFinite(oscale.y)) {
            logPhysicsState("updateOutputs:scaleNonFinite",
                text("outputScale=", oscale));
            return;
        }

        // Okay, so this is confusing. We want to translate the angle back to local space,
        // but not the coordinates.

        // Transform the physics output back into local space.
        // The origin here is the anchor. This gives us the local angle.
        vec4 localPos4;
        localPos4 = localOnly ? 
        vec4(output.x, output.y, 0, 1) : 
        ((prevAnchorSet? prevTransMat: transform.matrix.inverse) * vec4(output.x, output.y, 0, 1));
        vec2 localAngle = vec2(localPos4.x, localPos4.y);
        if (!isFinite(localPos4.x) || !isFinite(localPos4.y)) {
            logPhysicsState("updateOutputs:localPosNonFinite",
                text("localPos=", vec2(localPos4.x, localPos4.y),
                     " prevAnchorSet=", prevAnchorSet,
                     " prevTransMat=", prevAnchorSet ? prevTransMat : transform.matrix.inverse));
            return;
        }

        float localAngleLen = localAngle.length;
        if (!isFinite(localAngleLen) || fabs(localAngleLen) <= float.epsilon) {
            logPhysicsState("updateOutputs:angleLengthInvalid",
                text("localAngle=", localAngle,
                     " length=", localAngleLen));
            return;
        }
        localAngle /= localAngleLen;

        // Figure out the relative length. We can work this out directly in global space.
        float lengthVal = getLength();
        if (!isFinite(lengthVal) || fabs(lengthVal) <= float.epsilon) {
            logPhysicsState("updateOutputs:lengthInvalid",
                text("length=", lengthVal));
            return;
        }
        float distanceVal = output.distance(anchor);
        if (!isFinite(distanceVal)) {
            logPhysicsState("updateOutputs:distanceInvalid",
                text("distance=", distanceVal));
            return;
        }
        auto relLength = distanceVal / lengthVal;
        if (!isFinite(relLength)) {
            logPhysicsState("updateOutputs:relLengthInvalid",
                text("relLength=", relLength,
                     " distance=", distanceVal,
                     " length=", lengthVal));
            return;
        }

        vec2 paramVal;
        switch (mapMode) {
            case ParamMapMode.XY:
                auto localPosNorm = localAngle * relLength;
                paramVal = localPosNorm - vec2(0, 1);
                paramVal.y = -paramVal.y; // Y goes up for params
                break;
            case ParamMapMode.AngleLength:
                float a = atan2(-localAngle.x, localAngle.y) / PI;
                paramVal = vec2(a, relLength);
                break;
            case ParamMapMode.YX:
                auto localPosNorm = localAngle * relLength;
                paramVal = localPosNorm - vec2(0, 1);
                paramVal.y = -paramVal.y; // Y goes up for params
                paramVal = vec2(paramVal.y, paramVal.x);
                break;
            case ParamMapMode.LengthAngle:
                float a = atan2(-localAngle.x, localAngle.y) / PI;
                paramVal = vec2(relLength, a);
                break;
            default: assert(0);
        }

        if (!isFinite(paramVal.x) || !isFinite(paramVal.y)) {
            logPhysicsState("updateOutputs:paramValInvalid",
                text("paramVal=", paramVal,
                     " mapMode=", mapMode,
                     " localAngle=", localAngle,
                     " relLength=", relLength));
            return;
        }

        vec2 paramOffset = vec2(paramVal.x * oscale.x, paramVal.y * oscale.y);
        if (!isFinite(paramOffset.x) || !isFinite(paramOffset.y)) {
            logPhysicsState("updateOutputs:paramOffsetNonFinite",
                text("paramOffset=", paramOffset,
                     " paramVal=", paramVal,
                     " outputScale=", oscale));
            return;
        }

        param.pushIOffset(paramOffset, ParamMergeMode.Forced);
        param.update();
    }

    override
    void reset() {
        updateInputs();

        switch (modelType) {
            case PhysicsModel.Pendulum:
                system = new Pendulum(this);
                break;
            case PhysicsModel.SpringPendulum:
                system = new SpringPendulum(this);
                break;
            default:
                assert(0);
        }
    }

    override
    void finalize() {
        param_ = puppet.findParameter(paramRef);
        super.finalize();
        reset();
    }

    override
    void drawDebug() {
        system.drawDebug();
    }

    Parameter param() {
        return param_;
    }

    void param(Parameter p) {
        param_ = p;
        if (p is null) paramRef = InInvalidUUID;
        else paramRef = p.uuid;
    }

    float getScale() {
        return puppet.physics.pixelsPerMeter;
    }

    PhysicsModel modelType() {
        return modelType_;
    }

    void modelType(PhysicsModel t) {
        modelType_ = t;
        reset();
    }

       override
    bool hasParam(string key) {
        if (super.hasParam(key)) return true;

        switch(key) {
            case "gravity":
            case "length":
            case "frequency":
            case "angleDamping":
            case "lengthDamping":
            case "outputScale.x":
            case "outputScale.y":
                return true;
            default:
                return false;
        }
    }

    override
    float getDefaultValue(string key) {
        // Skip our list of our parent already handled it
        float def = super.getDefaultValue(key);
        if (!isNaN(def)) return def;

        switch(key) {
            case "gravity":
            case "frequency":
            case "angleDamping":
            case "lengthDamping":
            case "outputScale.x":
            case "outputScale.y":
                return 1;
            case "length":
                return 0;
            default: return float();
        }
    }

    override
    bool setValue(string key, float value) {
        
        // Skip our list of our parent already handled it
        if (super.setValue(key, value)) return true;

        switch(key) {
            case "gravity":
                offsetGravity *= value;
                return true;
            case "length":
                offsetLength += value;
                return true;
            case "frequency":
                offsetFrequency *= value;
                return true;
            case "angleDamping":
                offsetAngleDamping *= value;
                return true;
            case "lengthDamping":
                offsetLengthDamping *= value;
                return true;
            case "outputScale.x":
                offsetOutputScale.x *= value;
                return true;
            case "outputScale.y":
                offsetOutputScale.y *= value;
                return true;
            default: return false;
        }
    }
    
    override
    float getValue(string key) {
        switch(key) {
            case "gravity":         return offsetGravity;
            case "length":          return offsetLength;
            case "frequency":       return offsetFrequency;
            case "angleDamping":    return offsetAngleDamping;
            case "lengthDamping":   return offsetLengthDamping;
            case "outputScale.x":   return offsetOutputScale.x;
            case "outputScale.y":   return offsetOutputScale.y;
            default:                return super.getValue(key);
        }
    }

    /// Gets the final gravity
    float getGravity() { return (gravity * offsetGravity) * puppet.physics.gravity * getScale(); }

    /// Gets the final length
    float getLength() { return length + offsetLength; }

    /// Gets the final frequency
    float getFrequency() { return frequency * offsetFrequency; }

    /// Gets the final angle damping
    float getAngleDamping() { return angleDamping * offsetAngleDamping; }

    /// Gets the final length damping
    float getLengthDamping() { return lengthDamping * offsetLengthDamping; }

    /// Gets the final length damping
    vec2 getOutputScale() { return outputScale * offsetOutputScale; }

    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);

        if (auto sphysics = cast(SimplePhysics)src) {
            modelType_ = sphysics.modelType_;
            mapMode = sphysics.mapMode;
            localOnly = sphysics.localOnly;
            gravity = sphysics.gravity;
            length = sphysics.length;
            frequency = sphysics.frequency;
            angleDamping = sphysics.angleDamping;
            lengthDamping = sphysics.lengthDamping;
            outputScale = sphysics.outputScale;
            prevAnchorSet = false;
            anchor = vec2(0, 0);
            reset();

            paramRef = sphysics.paramRef;
            param_ = sphysics.param_;
        }
    }

}

mixin InNode!SimplePhysics;
