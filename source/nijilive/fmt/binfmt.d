module nijilive.fmt.binfmt;
import std.bitmanip;

/**
    Entrypoint magic bytes that define this is an nijilive puppet

    Trans Rights!
*/
enum MAGIC_BYTES = cast(ubyte[])"TRNSRTS\0";

enum TEX_SECTION = cast(ubyte[])"TEX_SECT";
enum EXT_SECTION = cast(ubyte[])"EXT_SECT";

/**
    Verifies that a buffer has the nijilive magic bytes present.
*/
bool inVerifyMagicBytes(ubyte[] buffer) {
    return inVerifySection(buffer, MAGIC_BYTES);
}

/**
    Verifies a section
*/
bool inVerifySection(ubyte[] buffer, ubyte[] section) {
    return buffer.length >= section.length && buffer[0..section.length] == section;
}

size_t inInterpretDataFromBuffer(T)(ubyte[] buffer, ref T data) {
    ubyte[T.sizeof] toInterp;
    toInterp[0..T.sizeof] = buffer[0..T.sizeof];

    data = bigEndianToNative!T(toInterp);
    return T.sizeof;
}