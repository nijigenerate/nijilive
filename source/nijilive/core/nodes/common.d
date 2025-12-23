/*
    nijilive Common Data
    previously Inochi2D Common Data

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.common;
import nijilive.fmt.serialize;
import std.string;

version (InDoesRender) {
    import nijilive.core.runtime_state : currentRenderBackend;

    private auto blendBackend() { return currentRenderBackend(); }

    void setAdvancedBlendCoherent(bool enabled) {
        blendBackend().setAdvancedBlendCoherent(enabled);
    }

    void setLegacyBlendMode(BlendMode blendingMode) {
        blendBackend().setLegacyBlendMode(blendingMode);
    }

    void setAdvancedBlendEquation(BlendMode blendingMode) {
        blendBackend().setAdvancedBlendEquation(blendingMode);
    }

    void issueBlendBarrier() {
        blendBackend().issueBlendBarrier();
    }

    bool hasAdvancedBlendSupport() {
        return blendBackend().supportsAdvancedBlend();
    }

    bool hasAdvancedBlendCoherentSupport() {
        return blendBackend().supportsAdvancedBlendCoherent();
    }
} else {
    void setAdvancedBlendCoherent(bool) { }
    void setLegacyBlendMode(BlendMode) { }
    void setAdvancedBlendEquation(BlendMode) { }
    void issueBlendBarrier() { }
    bool hasAdvancedBlendSupport() { return false; }
    bool hasAdvancedBlendCoherentSupport() { return false; }
}

private {
    bool inAdvancedBlending;
    bool inAdvancedBlendingCoherent;
    version(OSX)
        enum bool inDefaultTripleBufferFallback = true;
    else
        enum bool inDefaultTripleBufferFallback = false;
    bool inForceTripleBufferFallback = inDefaultTripleBufferFallback;
    bool inAdvancedBlendingAvailable;
    bool inAdvancedBlendingCoherentAvailable;

    void inApplyBlendingCapabilities() {
        bool desiredAdvanced = inAdvancedBlendingAvailable && !inForceTripleBufferFallback;
        bool desiredCoherent = inAdvancedBlendingCoherentAvailable && !inForceTripleBufferFallback;

        if (desiredCoherent != inAdvancedBlendingCoherent) {
            setAdvancedBlendCoherent(desiredCoherent);
        }

        inAdvancedBlending = desiredAdvanced;
        inAdvancedBlendingCoherent = desiredCoherent;
    }

    void inSetBlendModeLegacy(BlendMode blendingMode) {
        setLegacyBlendMode(blendingMode);
    }
}

/**
    Whether a multi-stage rendering pass should be used for blending
*/
bool inUseMultistageBlending(BlendMode blendingMode) {
    if (inForceTripleBufferFallback) return false;
    switch(blendingMode) {
        case BlendMode.Normal,
             BlendMode.LinearDodge,
             BlendMode.AddGlow,
             BlendMode.Subtract,
             BlendMode.Inverse,
             BlendMode.DestinationIn,
             BlendMode.ClipToLower,
             BlendMode.SliceFromLower:
                 return false;
        default: return inAdvancedBlending;
    }
}

void nlApplyBlendingCapabilities() {
    inApplyBlendingCapabilities();
}

void inInitBlending() {
    inForceTripleBufferFallback = inDefaultTripleBufferFallback;
    inAdvancedBlendingAvailable = hasAdvancedBlendSupport();
    inAdvancedBlendingCoherentAvailable = hasAdvancedBlendCoherentSupport();
    inApplyBlendingCapabilities();
}

void nlSetTripleBufferFallback(bool enable) {
    if (inForceTripleBufferFallback == enable) return;
    inForceTripleBufferFallback = enable;
    inApplyBlendingCapabilities();
}

bool nlIsTripleBufferFallbackEnabled() {
    return inForceTripleBufferFallback;
}

/*
    INFORMATION ABOUT BLENDING MODES
    Blending is a complicated topic, especially once we get to mobile devices and games consoles.

    The following blending modes are supported in Standard mode:
        Normal
        Multiply
        Screen
        Overlay
        Darken
        Lighten
        Color Dodge
        Linear Dodge
        Add (Glow)
        Color Burn
        Hard Light
        Soft Light
        Difference
        Exclusion
        Subtract
        Inverse
        Destination In
        Clip To Lower
        Slice from Lower
    Some of these blending modes behave better on Tiling GPUs.

    The following blending modes are supported in Core mode:
        Normal
        Multiply
        Screen
        Lighten
        Color Dodge
        Linear Dodge
        Add (Glow)
        Inverse
        Destination In
        Clip to Lower
        Slice from Lower
    Tiling GPUs on older mobile devices don't have great drivers, we shouldn't tempt fate.
*/

/**
    Blending modes
*/
enum BlendMode {
    // Normal blending mode
    Normal,

    // Multiply blending mode
    Multiply,

    // Screen
    Screen,

    // Overlay
    Overlay,

    // Darken
    Darken,

    // Lighten
    Lighten,
    
    // Color Dodge
    ColorDodge,

    // Linear Dodge
    LinearDodge,

    // Add (Glow)
    AddGlow,

    // Color Burn
    ColorBurn,

    // Hard Light
    HardLight,

    // Soft Light
    SoftLight,

    // Difference
    Difference,

    // Exclusion
    Exclusion,

    // Subtract
    Subtract,

    // Inverse
    Inverse,

    // Destination In
    DestinationIn,

    // Clip to Lower
    // Special blending mode that clips the drawable
    // to a lower rendered area.
    ClipToLower,

    // Slice from Lower
    // Special blending mode that slices the drawable
    // via a lower rendered area.
    // Basically inverse ClipToLower
    SliceFromLower
}

bool inIsAdvancedBlendMode(BlendMode mode) {
    if (!inAdvancedBlending) return false;
    switch(mode) {
        case BlendMode.Multiply:
        case BlendMode.Screen: 
        case BlendMode.Overlay: 
        case BlendMode.Darken: 
        case BlendMode.Lighten: 
        case BlendMode.ColorDodge: 
        case BlendMode.ColorBurn: 
        case BlendMode.HardLight: 
        case BlendMode.SoftLight: 
        case BlendMode.Difference: 
        case BlendMode.Exclusion: 
            return true;
        
        // Fallback to legacy
        default: 
            return false;
    }
}

void inSetBlendMode(BlendMode blendingMode, bool legacyOnly=false) {
    if (!inAdvancedBlending || legacyOnly) inSetBlendModeLegacy(blendingMode);
    else setAdvancedBlendEquation(blendingMode);
}

void inBlendModeBarrier(BlendMode mode) {
    if (inAdvancedBlending && !inAdvancedBlendingCoherent && inIsAdvancedBlendMode(mode)) 
        issueBlendBarrier();
}

/**
    Masking mode
*/
enum MaskingMode {

    /**
        The part should be masked by the drawables specified
    */
    Mask,

    /**
        The path should be dodge masked by the drawables specified
    */
    DodgeMask
}

/**
    A binding between a mask and a mode
*/
struct MaskBinding {
public:
    import nijilive.core.nodes.drawable : Drawable;
    @Name("source")
    uint maskSrcUUID;

    @Name("mode")
    MaskingMode mode;
    
    @Ignore
    Drawable maskSrc;
}
