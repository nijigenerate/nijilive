/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.texture;
import nijilive.math;
import std.exception;
import std.format;
import imagefmt;
import std.algorithm : clamp;
import nijilive.core.nodes : inCreateUUID;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.core.render.backends.opengl.texture_backend;

/**
    A texture which is not bound to an OpenGL context
    Used for texture atlassing
*/
struct ShallowTexture {
public:
    /**
        8-bit RGBA color data
    */
    ubyte[] data;

    /**
        Width of texture
    */
    int width;

    /**
        Height of texture
    */
    int height;

    /**
        Amount of color channels
    */
    int channels;

    /**
        Amount of channels to conver to when passed to OpenGL
    */
    int convChannels;

    /**
        Loads a shallow texture from image file
        Supported file types:
        * PNG 8-bit
        * BMP 8-bit
        * TGA 8-bit non-palleted
        * JPEG baseline
    */
    this(string file, int channels = 0) {
        import std.file : read;

        // Ensure we keep this ref alive until we're done with it
        ubyte[] fData = cast(ubyte[])read(file);

        // Load image from disk, as <channels> 8-bit
        IFImage image = read_image(fData, 0, 8);
        enforce( image.e == 0, "%s: %s".format(IF_ERROR[image.e], file));
        scope(exit) image.free();

        // Copy data from IFImage to this ShallowTexture
        this.data = new ubyte[image.buf8.length];
        this.data[] = image.buf8;

        // Set the width/height data
        this.width = image.w;
        this.height = image.h;
        this.channels = image.c;
        this.convChannels = channels == 0 ? image.c : channels;
    }

    /**
        Loads a shallow texture from image buffer
        Supported file types:
        * PNG 8-bit
        * BMP 8-bit
        * TGA 8-bit non-palleted
        * JPEG baseline

        By setting channels to a specific value you can force a specific color mode
    */
    this(ubyte[] buffer, int channels = 0) {

        // Load image from disk, as <channels> 8-bit
        IFImage image = read_image(buffer, 0, 8);
        enforce( image.e == 0, "%s".format(IF_ERROR[image.e]));
        scope(exit) image.free();

        // Copy data from IFImage to this ShallowTexture
        this.data = new ubyte[image.buf8.length];
        this.data[] = image.buf8;

        // Set the width/height data
        this.width = image.w;
        this.height = image.h;
        this.channels = image.c;
        this.convChannels = channels == 0 ? image.c : channels;
    }
    
    /**
        Loads uncompressed texture from memory
    */
    this(ubyte[] buffer, int w, int h, int channels = 4) {
        this.data = buffer;

        // Set the width/height data
        this.width = w;
        this.height = h;
        this.channels = channels;
        this.convChannels = channels;
    }
    
    /**
        Loads uncompressed texture from memory
    */
    this(ubyte[] buffer, int w, int h, int channels = 4, int convChannels = 4) {
        this.data = buffer;

        // Set the width/height data
        this.width = w;
        this.height = h;
        this.channels = channels;
        this.convChannels = convChannels;
    }

    /**
        Saves image
    */
    void save(string file) {
        import std.file : write;
        import core.stdc.stdlib : free;
        int e;
        ubyte[] sData = write_image_mem(IF_PNG, this.width, this.height, this.data, channels, e);
        enforce(!e, "%s".format(IF_ERROR[e]));

        write(file, sData);

        // Make sure we free the buffer
        free(sData.ptr);
    }
}

/**
    A texture, only format supported is unsigned 8 bit RGBA
*/
class Texture {
private:
    uint id;
    int width_;
    int height_;
    int channels_;
    bool stencil_;

    uint uuid;

    ubyte[] lockedData = null;
    bool locked = false;
    bool modified = false;

public:

    /**
        Loads texture from image file
        Supported file types:
        * PNG 8-bit
        * BMP 8-bit
        * TGA 8-bit non-palleted
        * JPEG baseline
    */
    this(string file, int channels = 0) {
        import std.file : read;

        // Ensure we keep this ref alive until we're done with it
        ubyte[] fData = cast(ubyte[])read(file);

        // Load image from disk, as RGBA 8-bit
        IFImage image = read_image(fData, 0, 8);
        enforce( image.e == 0, "%s: %s".format(IF_ERROR[image.e], file));
        scope(exit) image.free();

        // Load in image data to OpenGL
        this(image.buf8, image.w, image.h, image.c, channels == 0 ? image.c : channels);
        uuid = inCreateUUID();
    }

    /**
        Creates a texture from a ShallowTexture
    */
    this(ShallowTexture shallow) {
        this(shallow.data, shallow.width, shallow.height, shallow.channels, shallow.convChannels);
    }

    /**
        Creates a new empty texture
    */
    this(int width, int height, int channels = 4, bool stencil = false) {

        // Create an empty texture array with no data
        ubyte[] empty = stencil? null: new ubyte[width_*height_*channels];

        // Pass it on to the other texturing
        this(empty, width, height, channels, channels, stencil);
    }

    /**
        Creates a new texture from specified data
    */
    this(ubyte[] data, int width, int height, int inChannels = 4, int outChannels = 4, bool stencil = false) {
        this.width_ = width;
        this.height_ = height;
        this.channels_ = outChannels;
        this.stencil_ = stencil;

        createTextureHandle(id);
        this.setData(data, inChannels);

        this.setFiltering(Filtering.Linear);
        this.setWrapping(Wrapping.Clamp);
        this.setAnisotropy(incGetMaxAnisotropy()/2.0f);
        uuid = inCreateUUID();
    }

    ~this() {
        dispose();
    }

    /**
        Width of texture
    */
    int width() {
        return width_;
    }

    /**
        Height of texture
    */
    int height() {
        return height_;
    }

    /**
        Gets the channel count
    */
    int channels() {
        return channels_;
    }

    /**
        Center of texture
    */
    vec2i center() {
        return vec2i(width_/2, height_/2);
    }

    /**
        Gets the size of the texture
    */
    vec2i size() {
        return vec2i(width_, height_);
    }

    /**
        Returns runtime UUID for texture
    */
    uint getRuntimeUUID() {
        return uuid;
    }

    /**
        Set the filtering mode used for the texture
    */
    void setFiltering(Filtering filtering) {
        applyTextureFiltering(id, filtering);
    }

    void setAnisotropy(float value) {
        applyTextureAnisotropy(id, clamp(value, 1, incGetMaxAnisotropy()));
    }

    /**
        Set the wrapping mode used for the texture
    */
    void setWrapping(Wrapping wrapping) {
        applyTextureWrapping(id, wrapping);
    }

    /**
        Sets the data of the texture
    */
    void setData(ubyte[] data, int inChannels) {
        if (locked) {
            lockedData = data;
            modified = true;
        } else {
            uploadTextureData(id, width_, height_, inChannels, channels_, stencil_, data);
            this.genMipmap();
        }
    }

    /**
        Generate mipmaps
    */
    void genMipmap() {
        if (!stencil_) {
            generateTextureMipmap(id);
        }
    }

    /**
        Sets a region of a texture to new data
    */
    void setDataRegion(ubyte[] data, int x, int y, int width, int height, int channels = -1) {
        auto actualChannels = channels == -1 ? this.channels_ : channels;

        // Make sure we don't try to change the texture in an out of bounds area.
        enforce( x >= 0 && x+width <= this.width_, "x offset is out of bounds (xoffset=%s, xbound=%s)".format(x+width, this.width_));
        enforce( y >= 0 && y+height <= this.height_, "y offset is out of bounds (yoffset=%s, ybound=%s)".format(y+height, this.height_));

        updateTextureRegion(id, x, y, width, height, actualChannels, data);

        this.genMipmap();
    }

    /**
        Bind this texture
        
        Notes
        - In release mode the unit value is clamped to 31 (The max OpenGL texture unit value)
        - In debug mode unit values over 31 will assert.
    */
    void bind(uint unit = 0) {
        assert(unit <= 31u, "Outside maximum OpenGL texture unit value");
        bindTextureHandle(id, unit);
    }

    /**
        Saves the texture to file
    */
    void save(string file) {
        write_image(file, width, height, getTextureData(true), channels_);
    }

    /**
        Gets the texture data for the texture
    */
    ubyte[] getTextureData(bool unmultiply=false) {
        if (locked) {
            return lockedData;
        } else {
            ubyte[] buf = new ubyte[width*height*channels_];
            readTextureData(id, channels_, stencil_, buf);
            if (unmultiply && channels == 4) {
                inTexUnPremuliply(buf);
            }
            return buf;
        }
    }

    /**
        Gets this texture's texture id
    */
    uint getTextureId() {
        return id;
    }

    /**
        Disposes texture from GL
    */
    void dispose() {
        deleteTextureHandle(id);
    }

    Texture dup() {
        auto result = new Texture(width_, height_, channels_, stencil_);
        result.setData(getTextureData(), channels_);
        return result;
    }

    void lock() {
        if (!locked) {
            lockedData = getTextureData();
            modified = false;
            locked = true;
        }
    }

    void unlock() {
        if (locked) {
            locked = false;
            if (modified)
                setData(lockedData, channels_);
            modified = false;
            lockedData = null;
        }
    }
}

private {
    Texture[] textureBindings;
    bool started = false;
}

/**
    Gets the maximum level of anisotropy
*/
float incGetMaxAnisotropy() {
    return maxTextureAnisotropy();
}

/**
    Begins a texture loading pass
*/
void inBeginTextureLoading() {
    enforce(!started, "Texture loading pass already started!");
    started = true;
}

/**
    Returns a texture from the internal texture list
*/
Texture inGetTextureFromId(uint id) {
    enforce(started, "Texture loading pass not started!");
    return textureBindings[cast(size_t)id];
}

/**
    Gets the latest texture from the internal texture list
*/
Texture inGetLatestTexture() {
    return textureBindings[$-1];
}

/**
    Adds binary texture
*/
void inAddTextureBinary(ShallowTexture data) {
    textureBindings ~= new Texture(data);
}

/**
    Ends a texture loading pass
*/
void inEndTextureLoading(bool checkErrors=true)() {
    static if (checkErrors) enforce(started, "Texture loading pass not started!");
    started = false;
    textureBindings.length = 0;
}

void inTexPremultiply(ref ubyte[] data, int channels = 4) {
    if (channels < 4) return;

    foreach(i; 0..data.length/channels) {

        size_t offsetPixel = (i*channels);
        data[offsetPixel+0] = cast(ubyte)((cast(int)data[offsetPixel+0] * cast(int)data[offsetPixel+3])/255);
        data[offsetPixel+1] = cast(ubyte)((cast(int)data[offsetPixel+1] * cast(int)data[offsetPixel+3])/255);
        data[offsetPixel+2] = cast(ubyte)((cast(int)data[offsetPixel+2] * cast(int)data[offsetPixel+3])/255);
    }
}

void inTexUnPremuliply(ref ubyte[] data) {
    foreach(i; 0..data.length/4) {
        if (data[((i*4)+3)] == 0) continue;

        data[((i*4)+0)] = cast(ubyte)(cast(int)data[((i*4)+0)] * 255 / cast(int)data[((i*4)+3)]);
        data[((i*4)+1)] = cast(ubyte)(cast(int)data[((i*4)+1)] * 255 / cast(int)data[((i*4)+3)]);
        data[((i*4)+2)] = cast(ubyte)(cast(int)data[((i*4)+2)] * 255 / cast(int)data[((i*4)+3)]);
    }
}
