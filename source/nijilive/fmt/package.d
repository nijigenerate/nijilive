/*
    nijilive Puppet file format
    previously Inochi2D Puppet file format

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.fmt;
import nijilive.fmt.binfmt;
public import nijilive.fmt.serialize;
import nijilive.integration;
import nijilive.core;
import std.bitmanip : nativeToBigEndian;
import std.exception;
import std.path;
import std.format;
import imagefmt;
import nijilive.fmt.io;

private bool isLoadingINP_ = false;

/**
    Gets whether the current loading state is set to INP loading
*/
bool inIsINPMode() {
    return isLoadingINP_;
}

/**
    Loads a puppet from a file
*/
T inLoadPuppet(T = Puppet)(string file) if (is(T : Puppet)) {
    try {
        import std.file : read;
        ubyte[] buffer = cast(ubyte[])read(file);

        switch(extension(file)) {

            case ".inp":
                enforce(inVerifyMagicBytes(buffer), "Invalid data format for INP puppet");
                return inLoadINPPuppet!T(buffer);

            case ".inx":
                enforce(inVerifyMagicBytes(buffer), "Invalid data format for nijigenerate INX");
                return inLoadINPPuppet!T(buffer);

            default:
                throw new Exception("Invalid file format of %s at path %s".format(extension(file), file));
        }
    } catch(Exception ex) {
        inEndTextureLoading!false();
        throw ex;
    }
}

/**
    Loads a puppet from memory
*/
Puppet inLoadPuppetFromMemory(ubyte[] data) {
    return deserialize!Puppet(cast(string)data);
}

/**
    Loads a JSON based puppet
*/
Puppet inLoadJSONPuppet(string data) {
    isLoadingINP_ = false;
    return inLoadJsonDataFromMemory!Puppet(data);
}

/**
    Loads a INP based puppet
*/
T inLoadINPPuppet(T = Puppet)(ubyte[] buffer) if (is(T : Puppet)) {
    size_t bufferOffset = 0;
    isLoadingINP_ = true;

    enforce(inVerifyMagicBytes(buffer), "Invalid data format for INP puppet");
    bufferOffset += 8; // Magic bytes are 8 bytes

    // Find the puppet data
    uint puppetDataLength;
    inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], puppetDataLength);

    string puppetData = cast(string)buffer[bufferOffset..bufferOffset+=puppetDataLength];

    enforce(inVerifySection(buffer[bufferOffset..bufferOffset+=8], TEX_SECTION), "Expected Texture Blob section, got nothing!");

    // Load textures in to memory
    version (InDoesRender) {
        inBeginTextureLoading();

        // Get amount of slots
        uint slotCount;
        inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], slotCount);

        Texture[] slots;
        foreach(i; 0..slotCount) {
            
            uint textureLength;
            inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], textureLength);

            ubyte textureType = buffer[bufferOffset++];
            if (textureLength == 0) {
                inAddTextureBinary(ShallowTexture([], 0, 0, 4));
            } else inAddTextureBinary(ShallowTexture(buffer[bufferOffset..bufferOffset+=textureLength]));
        
            // Readd to puppet so that stuff doesn't break if we re-save the puppet
            slots ~= inGetLatestTexture();
        }

        T puppet = inLoadJsonDataFromMemory!T(puppetData);
        puppet.textureSlots = slots;
        puppet.updateTextureState();
        inEndTextureLoading();
    } else version(InRenderless) {
        inCurrentPuppetTextureSlots.length = 0;

        // Get amount of slots
        uint slotCount;
        inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], slotCount);
        foreach(i; 0..slotCount) {
            
            uint textureLength;
            inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], textureLength);

            ubyte textureType = buffer[bufferOffset++];
            if (textureLength == 0) {
                continue;
            } else inCurrentPuppetTextureSlots ~= TextureBlob(textureType, buffer[bufferOffset..bufferOffset+=textureLength]);
        }

        T puppet = inLoadJsonDataFromMemory!T(puppetData);
    }

    if (buffer.length >= bufferOffset + 8 && inVerifySection(buffer[bufferOffset..bufferOffset+=8], EXT_SECTION)) {
        uint sectionCount;
        inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], sectionCount);

        foreach(section; 0..sectionCount) {
            import std.json : parseJSON;

            // Get name of payload/vendor extended data
            uint sectionNameLength;
            inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], sectionNameLength);            
            string sectionName = cast(string)buffer[bufferOffset..bufferOffset+=sectionNameLength];

            // Get length of data
            uint payloadLength;
            inInterpretDataFromBuffer(buffer[bufferOffset..bufferOffset+=4], payloadLength);

            // Load the vendor JSON data in to the extData section of the puppet
            ubyte[] payload = buffer[bufferOffset..bufferOffset+=payloadLength];
            puppet.extData[sectionName] = payload;
        }
    }
    
    // We're done!
    return puppet;
}

/**
    Only write changed EXT section portions to puppet file
*/
void inWriteINPExtensions(Puppet p, string file) {
    import std.stdio : File;
    import stdfile = std.file; 
    size_t extSectionStart, extSectionEnd;
    bool foundExtSection;
    File f = File(file, "rb");

    // Verify that we're in an INP file
    enforce(inVerifyMagicBytes(f.read(MAGIC_BYTES.length)), "Invalid data format for INP puppet");

    // Read puppet payload
    uint puppetSectionLength = f.readValue!uint;
    f.skip(puppetSectionLength);

    // Verify texture section magic bytes
    enforce(inVerifySection(f.read(TEX_SECTION.length), TEX_SECTION), "Expected Texture Blob section, got nothing!");

    uint slotCount = f.readValue!uint;
    foreach(slot; 0..slotCount) {
        uint length = f.readValue!uint;
        f.skip(length+1);
    }

    // Only do this if there is an extended section here
    if (inVerifySection(f.peek(EXT_SECTION.length), EXT_SECTION)) {
        foundExtSection = true;

        extSectionStart = f.tell();
        f.skip(EXT_SECTION.length);
        
        uint payloadCount = f.readValue!uint;
        foreach(pc; 0..payloadCount) {

            uint nameLength = f.readValue!uint;
            f.skip(nameLength);

            uint payloadLength = f.readValue!uint;
            f.skip(payloadLength);
        }
        extSectionEnd = f.tell();
    }
    f.close();

    ubyte[] fdata = cast(ubyte[])stdfile.read(file);
    ubyte[] app = fdata;
    if (foundExtSection) {
        // If the extended section was found, reuse it.
        app = fdata[0..extSectionStart];
        ubyte[] end = fdata[extSectionEnd..$];

        // Don't waste bytes on empty EXT data sections
        if (p.extData.length > 0) {
            // Begin extended section
            app ~= EXT_SECTION;
            app ~= nativeToBigEndian(cast(uint)p.extData.length)[0..4];

            foreach(name, payload; p.extData) {
                
                // Write payload name and its length
                app ~= nativeToBigEndian(cast(uint)name.length)[0..4];
                app ~= cast(ubyte[])name;

                // Write payload length and payload
                app ~= nativeToBigEndian(cast(uint)payload.length)[0..4];
                app ~= payload;

            }
        }

        app ~= end;

    } else {
        // Otherwise, make a new one

        // Don't waste bytes on empty EXT data sections
        if (p.extData.length > 0) {
            // Begin extended section
            app ~= EXT_SECTION;
            app ~= nativeToBigEndian(cast(uint)p.extData.length)[0..4];

            foreach(name, payload; p.extData) {
                
                // Write payload name and its length
                app ~= nativeToBigEndian(cast(uint)name.length)[0..4];
                app ~= cast(ubyte[])name;

                // Write payload length and payload
                app ~= nativeToBigEndian(cast(uint)payload.length)[0..4];
                app ~= payload;

            }
        }
    }

    // write our final file out
    stdfile.write(file, app);
}

/**
    Writes out a model to memory
*/
ubyte[] inWriteINPPuppetMemory(Puppet p) {
    import nijilive.ver : IN_VERSION;
    import std.range : appender;
    import std.json : JSONValue;

    isLoadingINP_ = true;
    auto app = appender!(ubyte[]);

    // Write the current used nijilive version to the version_ meta tag.
    p.meta.version_ = IN_VERSION;
    string puppetJson = inToJson(p);

    app ~= MAGIC_BYTES;
    app ~= nativeToBigEndian(cast(uint)puppetJson.length)[0..4];
    app ~= cast(ubyte[])puppetJson;
    
    // Begin texture section
    app ~= TEX_SECTION;
    app ~= nativeToBigEndian(cast(uint)p.textureSlots.length)[0..4];
    foreach(texture; p.textureSlots) {
        int e;
        ubyte[] tex = write_image_mem(IF_TGA, texture.width, texture.height, texture.getTextureData(), texture.channels, e);
        app ~= nativeToBigEndian(cast(uint)tex.length)[0..4];
        app ~= (cast(ubyte)IN_TEX_TGA);
        app ~= (tex);
    }

    // Don't waste bytes on empty EXT data sections
    if (p.extData.length > 0) {
        // Begin extended section
        app ~= EXT_SECTION;
        app ~= nativeToBigEndian(cast(uint)p.extData.length)[0..4];

        foreach(name, payload; p.extData) {
            
            // Write payload name and its length
            app ~= nativeToBigEndian(cast(uint)name.length)[0..4];
            app ~= cast(ubyte[])name;

            // Write payload length and payload
            app ~= nativeToBigEndian(cast(uint)payload.length)[0..4];
            app ~= payload;

        }
    }

    return app.data;
}

/**
    Writes nijilive puppet to file
*/
void inWriteINPPuppet(Puppet p, string file) {
    import std.file : write;

    // Write it out to file
    write(file, inWriteINPPuppetMemory(p));
}

enum IN_TEX_PNG = 0u; /// PNG encoded nijilive texture
enum IN_TEX_TGA = 1u; /// TGA encoded nijilive texture
enum IN_TEX_BC7 = 2u; /// BC7 encoded nijilive texture

/**
    Writes a puppet to file
*/
void inWriteJSONPuppet(Puppet p, string file) {
    import std.file : write;
    isLoadingINP_ = false;
    write(file, inToJson(p));
}
