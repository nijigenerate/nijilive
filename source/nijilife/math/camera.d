/*
    nijilife Camera

    Copyright © 2020, nijilife Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilife.math.camera;
import nijilife.math;
import nijilife;
import std.math : isFinite;

/**
    An orthographic camera
*/
class Camera {
private:
    mat4 projection;

public:

    /**
        Position of camera
    */
    vec2 position = vec2(0, 0);

    /**
        Rotation of the camera
    */
    float rotation = 0f;

    /**
        Size of the camera
    */
    vec2 scale = vec2(1, 1);

    vec2 getRealSize() {
        int width, height;
        inGetViewport(width, height);

        return vec2(cast(float)width/scale.x, cast(float)height/scale.y);
    }

    vec2 getCenterOffset() {
        vec2 realSize = getRealSize();
        return realSize/2;
    }

    /**
        Matrix for this camera

        width = width of camera area
        height = height of camera area
    */
    mat4 matrix() {
        if(!position.isFinite) position = vec2(0);
        if(!scale.isFinite) scale = vec2(1);
        if(!rotation.isFinite) rotation = 0;

        vec2 realSize = getRealSize();
        if(!realSize.isFinite) return mat4.identity;
        
        vec2 origin = vec2(realSize.x/2, realSize.y/2);
        vec3 pos = vec3(position.x, position.y, -(ushort.max/2));

        return 
            mat4.orthographic(0f, realSize.x, realSize.y, 0, 0, ushort.max) * 
            mat4.translation(origin.x, origin.y, 0) *
            mat4.zRotation(rotation) *
            mat4.translation(pos);
    }
}