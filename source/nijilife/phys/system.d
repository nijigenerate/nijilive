/*
    Copyright © 2022, nijilife Project
    Distributed under the 2-Clause BSD License, see LICENSE file.

    Author Asahi Lina
*/
module nijilife.phys.system;
import nijilife;
import std.math : isFinite;

abstract class PhysicsSystem {
private:
    ulong[float*] variableMap;
    float*[] refs;
    float[] derivative;

    float t;

protected:
    /**
        Add a float variable to the simulation
    */
    ulong addVariable(float* var) {
        ulong index = refs.length;

        variableMap[var] = index;
        refs ~= var;

        return index;
    }

    /**
        Add a vec2 variable to the simulation
    */
    ulong addVariable(vec2* var) {
        ulong index = addVariable(&(var.vector[0]));
        addVariable(&(var.vector[1]));
        return index;
    }

    /**
        Set the derivative of a variable (solver input) by index
    */
    void setD(ulong index, float value) {
        derivative[index] = value;
    }

    /**
        Set the derivative of a float variable (solver input)
    */
    void setD(ref float var, float value) {
        ulong index = variableMap[&var];
        setD(variableMap[&var], value);
    }

    /**
        Set the derivative of a vec2 variable (solver input)
    */
    void setD(ref vec2 var, vec2 value) {
        setD(var.vector[0], value.x);
        setD(var.vector[1], value.y);
    }

    float[] getState() {
        float[] vals;

        foreach(idx, ptr; refs) {
            vals ~= *ptr;
        }

        return vals;
    }

    void setState(float[] vals) {
        foreach(idx, ptr; refs) {
            *ptr = vals[idx];
        }
    }

    /**
        Evaluate the simulation at a given time
    */
    abstract void eval(float t);

public:
    /**
        Run a simulation tick (Runge-Kutta method)
    */
    void tick(float h) {
        float[] cur = getState();
        float[] tmp;
        tmp.length = cur.length;
        derivative.length = cur.length;
        foreach(i; 0..derivative.length)
            derivative[i] = 0;

        eval(t);
        float[] k1 = derivative.dup;

        foreach(i; 0..cur.length)
            *refs[i] = cur[i] + h * k1[i] / 2f;
        eval(t + h / 2f);
        float[] k2 = derivative.dup;

        foreach(i; 0..cur.length)
            *refs[i] = cur[i] + h * k2[i] / 2f;
        eval(t + h / 2f);
        float[] k3 = derivative.dup;

        foreach(i; 0..cur.length)
            *refs[i] = cur[i] + h * k3[i];
        eval(t + h);
        float[] k4 = derivative.dup;

        foreach(i; 0..cur.length) {
            *refs[i] = cur[i] + h * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]) / 6f;
            if (!isFinite(*refs[i])) {
                // Simulation failed, revert
                foreach(j; 0..cur.length)
                    *refs[j] = cur[j];
                break;
            }
        }

        t += h;
    }

public:

    /**
        Updates the anchor for the physics system
    */
    abstract void updateAnchor();

    /**
        Draw debug
    */
    abstract void drawDebug(mat4 trans = mat4.identity);
}

