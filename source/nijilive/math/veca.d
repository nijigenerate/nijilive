module nijilive.math.veca;

import std.math : approxEqual;
import std.traits : isFloatingPoint, isIntegral, Unqual;
import inmath.linalg : Vector;
import core.memory : GC;
import core.simd;

enum simdAlignment = 16;

/// Struct-of-arrays storage for vector data of size `N`.
struct veca(T, size_t N)
if (N > 0) {
    alias Element = Vector!(T, N);
    package(nijilive) T[][N] lanes;
private:
    T[] backing;
    size_t logicalLength;
    size_t laneStride;
    size_t laneBase;
    size_t viewCapacity;
    bool ownsStorage = true;

    void rebindLanes() @trusted {
        foreach (laneIdx; 0 .. N) {
            if (logicalLength == 0 || backing.length == 0) {
                lanes[laneIdx] = null;
            } else {
                auto stride = laneStride ? laneStride : logicalLength;
                auto start = laneIdx * stride + laneBase;
                lanes[laneIdx] = backing[start .. start + logicalLength];
            }
        }
    }

    T[] snap(size_t totalElements) @trusted {
        enum size_t mask = simdAlignment - 1;
        auto bytes = totalElements * T.sizeof + mask;
        auto rawMem = cast(ubyte*)GC.malloc(bytes, GC.BlkAttr.NO_SCAN);
        assert(rawMem !is null, "Failed to allocate veca backing buffer");
        auto alignedAddr = (cast(size_t)rawMem + mask) & ~mask;
        auto result = cast(T*)alignedAddr;
        // We intentionally skip zero-initialization to avoid an O(n) fill;
        // callers are expected to overwrite the storage before reading.
        return result[0 .. totalElements];
    }

    void allocateBacking(size_t len) @trusted {
        if (len == 0) {
            backing.length = 0;
            logicalLength = 0;
            laneStride = 0;
            laneBase = 0;
            viewCapacity = 0;
            ownsStorage = true;
            rebindLanes();
            return;
        }
        auto oldBacking = backing;
        auto oldStride = laneStride ? laneStride : logicalLength;
        auto oldBase = laneBase;
        auto oldLength = logicalLength;

        const size_t totalElements = len * N;
        auto newBacking = snap(totalElements);
        size_t copyLen = 0;
        static if (N) {
            if (oldLength && len) {
                copyLen = oldLength < len ? oldLength : len;
            }
        }
        if (copyLen && oldBacking.length) {
            foreach (laneIdx; 0 .. N) {
                auto dstStart = laneIdx * len;
                auto srcStart = laneIdx * oldStride + oldBase;
                newBacking[dstStart .. dstStart + copyLen] =
                    oldBacking[srcStart .. srcStart + copyLen];
            }
        }
        backing = newBacking;
        logicalLength = len;
        laneStride = len;
        laneBase = 0;
        viewCapacity = len;
        ownsStorage = true;
        rebindLanes();
    }
public:

    this(size_t length) {
        ensureLength(length);
    }

    this(Element[] values) {
        assign(values);
    }

    this(Element value) {
        ensureLength(1);
        this[0] = value;
    }

    /// Number of logical vectors stored.
    @property size_t length() const {
        return logicalLength;
    }

    /// Update logical vector count (behaves like dynamic array length).
    @property void length(size_t newLength) {
        ensureLength(newLength);
    }

    @property size_t opDollar() const {
        return length;
    }

    /// Ensure every component lane has the given length.
    void ensureLength(size_t len) {
        if (logicalLength == len) {
            return;
        }
        if (ownsStorage) {
            allocateBacking(len);
        } else {
            assert(len <= viewCapacity, "veca view length exceeds capacity");
            logicalLength = len;
            rebindLanes();
        }
    }

    /// Append a new vector value to the storage.
    void append(Element value) {
        ensureLength(length + 1);
        this[length - 1] = value;
    }

    /// Read/write accessors that expose a view over the underlying SoA slot.
    vecv!(T, N) opIndex(size_t idx) @trusted {
        assert(idx < length, "veca index out of range");
        return vecv!(T, N)(lanes, idx);
    }

    vecvConst!(T, N) opIndex(size_t idx) const @trusted {
        assert(idx < length, "veca index out of range");
        auto ptr = cast(const(T[][N])*)&this.lanes;
        return vecvConst!(T, N)(ptr, idx);
    }

    /// Assign from a dense AoS array.
    void assign(const Element[] source) {
        length = source.length;
        foreach (i, vec; source) {
            this[i] = vec;
        }
    }

    ref veca opAssign(veca rhs) {
        auto len = rhs.length;
        ensureLength(len);
        if (len == 0) {
            return this;
        }
        foreach (laneIdx; 0 .. N) {
            auto dst = lanes[laneIdx][0 .. len];
            auto src = rhs.lanes[laneIdx][0 .. len];
            if (dst.ptr is src.ptr) {
                continue;
            }
            auto copyBytes = len * T.sizeof;
            () @trusted {
                import core.stdc.string : memmove;
                memmove(dst.ptr, src.ptr, copyBytes);
            }();
        }
        return this;
    }

    /// Element-wise arithmetic implemented through SIMD or slices.
    void opOpAssign(string op)(const veca!(T, N) rhs)
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        assert(length == rhs.length, "Mismatched vector lengths");
        foreach (i; 0 .. N) {
            static if (isSIMDCompatible!T) {
                auto dstLane = lanes[i];
                auto srcLane = rhs.lanes[i];
                if (canApplySIMD(dstLane, srcLane)) {
                    applySIMD!(op)(dstLane, srcLane);
                    continue;
                }
            }
            auto dstSlice = lanes[i];
            auto srcSlice = rhs.lanes[i];
            static if (op == "+")
                dstSlice[] += srcSlice[];
            else static if (op == "-")
                dstSlice[] -= srcSlice[];
            else static if (op == "*")
                dstSlice[] *= srcSlice[];
            else
                dstSlice[] /= srcSlice[];
        }
    }

    /// Apply a constant vector across all elements.
    void opOpAssign(string op)(Vector!(T, N) rhs)
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        foreach (laneIdx; 0 .. N) {
            auto lane = lanes[laneIdx];
            auto scalar = rhs.vector[laneIdx];
            static if (op == "+")
                lane[] += scalar;
            else static if (op == "-")
                lane[] -= scalar;
            else static if (op == "*")
                lane[] *= scalar;
            else
                lane[] /= scalar;
        }
    }

    /// Apply a scalar across all components.
    void opOpAssign(string op, U)(U rhs)
    if ((op == "+" || op == "-" || op == "*" || op == "/") && is(typeof(cast(T) rhs))) {
        auto scalar = cast(T)rhs;
        foreach (laneIdx; 0 .. N) {
            auto lane = lanes[laneIdx];
            static if (op == "+")
                lane[] += scalar;
            else static if (op == "-")
                lane[] -= scalar;
            else static if (op == "*")
                lane[] *= scalar;
            else
                lane[] /= scalar;
        }
    }

    /// Create a dense AoS `Vector` array copy.
    Element[] toArray() const {
        auto result = new Element[length];
        foreach (i; 0 .. length)
            result[i] = this[i].toVector();
        return result;
    }

    /// Write the SoA data into a provided AoS buffer.
    void toArrayInto(ref Element[] target) const {
        target.length = length;
        foreach (i; 0 .. length)
            target[i] = this[i].toVector();
    }

    /// Duplicate the SoA buffer.
    veca dup() const {
        veca copy;
        copy.ensureLength(logicalLength);
        foreach (laneIdx; 0 .. N) {
            if (logicalLength == 0) break;
            copy.lanes[laneIdx][] = lanes[laneIdx][];
        }
        return copy;
    }

    /// Clear all stored vectors.
    void clear() {
        logicalLength = 0;
        if (ownsStorage) {
            backing.length = 0;
        } else {
            backing = null;
        }
        laneStride = 0;
        laneBase = 0;
        viewCapacity = 0;
        rebindLanes();
    }

    /// Append element(s) using array-like syntax.
    void opOpAssign(string op, U)(auto ref U value)
    if (op == "~") {
        static if (is(Unqual!U == veca!(T, N)))
            appendArray(value);
        else static if (is(U == vecv!(T, N)) || is(U == vecvConst!(T, N)))
            append(value.toVector());
        else static if (is(U == Element))
            append(value);
        else static if (is(U : const(Element)[]))
            appendAoS(value);
        else static assert(0, "Unsupported append type for veca");
    }

    auto opBinary(string op)(const veca rhs) const
    if (op == "~") {
        auto copy = dup();
        copy ~= rhs;
        return copy;
    }

    auto opBinary(string op)(Element rhs) const
    if (op == "~") {
        auto copy = dup();
        copy ~= rhs;
        return copy;
    }

    auto opBinaryRight(string op)(Element lhs) const
    if (op == "~") {
        veca result;
        result ~= lhs;
        result ~= this;
        return result;
    }

    veca opSlice() const {
        return dup();
    }

    /// Direct access to a component lane.
    inout(T)[] lane(size_t component) inout {
        assert(component < N, "veca lane index out of range");
        return lanes[component];
    }

    package(nijilive) inout(T)[] rawStorage() inout {
        assert(laneBase == 0 && (laneStride == logicalLength || laneStride == 0),
               "rawStorage is only available for owned contiguous buffers");
        return backing;
    }

    package(nijilive) void bindExternalStorage(ref veca storage, size_t offset, size_t length) {
        if (length == 0 || storage.backing.length == 0) {
            ownsStorage = false;
            backing = null;
            logicalLength = 0;
            viewCapacity = 0;
            laneStride = storage.logicalLength;
            laneBase = offset;
            rebindLanes();
            return;
        }
        ownsStorage = false;
        backing = storage.backing;
        laneStride = storage.logicalLength;
        laneBase = offset;
        logicalLength = length;
        viewCapacity = length;
        rebindLanes();
    }

    void opSliceAssign(veca rhs) {
        ensureLength(rhs.length);
        foreach (laneIdx; 0 .. N) {
            lanes[laneIdx][] = rhs.lanes[laneIdx][];
        }
    }

    void opSliceAssign(const Element[] values) {
        assign(values);
    }

    void opSliceAssign(Element value) {
        foreach (laneIdx; 0 .. N) {
            lanes[laneIdx][] = value.vector[laneIdx];
        }
    }

    vecv!(T, N) front() {
        return this[0];
    }

    vecv!(T, N) back() {
        return this[length - 1];
    }

    vecvConst!(T, N) front() const {
        return this[0];
    }

    vecvConst!(T, N) back() const {
        return this[length - 1];
    }

    @property bool empty() const {
        return length == 0;
    }

    int opApply(int delegate(vecv!(T, N)) dg) {
        foreach (i; 0 .. length) {
            auto view = vecv!(T, N)(lanes, i);
            auto res = dg(view);
            if (res) return res;
        }
        return 0;
    }

    int opApply(int delegate(size_t, vecv!(T, N)) dg) {
        foreach (i; 0 .. length) {
            auto view = vecv!(T, N)(lanes, i);
            auto res = dg(i, view);
            if (res) return res;
        }
        return 0;
    }

    int opApply(int delegate(vecvConst!(T, N)) dg) const {
        auto ptr = cast(const(T[][N])*)&this.lanes;
        foreach (i; 0 .. length) {
            auto view = vecvConst!(T, N)(ptr, i);
            auto res = dg(view);
            if (res) return res;
        }
        return 0;
    }

    int opApply(int delegate(size_t, vecvConst!(T, N)) dg) const {
        auto ptr = cast(const(T[][N])*)&this.lanes;
        foreach (i; 0 .. length) {
            auto view = vecvConst!(T, N)(ptr, i);
            auto res = dg(i, view);
            if (res) return res;
        }
        return 0;
    }

private:
    void appendArray(in veca rhs) {
        auto oldLen = length;
        ensureLength(oldLen + rhs.length);
        foreach (i; 0 .. N) {
            lanes[i][oldLen .. oldLen + rhs.length] = rhs.lanes[i][];
        }
    }

    void appendAoS(const Element[] values) {
        auto oldLen = length;
        ensureLength(oldLen + values.length);
        foreach (idx, vec; values) {
            this[oldLen + idx] = vec;
        }
    }
}

/// Mutable view into a single element of `veca`.
struct vecv(T, size_t N) {
    alias VectorType = Vector!(T, N);
    private T[][N]* lanes;
    private size_t index;

    this(ref T[][N] storage, size_t idx) @trusted {
        lanes = &storage;
        index = idx;
    }

    this(ref T[][N] storage, size_t idx, Vector!(T, N) initial) {
        this(storage, idx);
        opAssign(initial);
    }

    ref T component(size_t lane) {
        assert(lanes !is null, "vecv is not bound to storage");
        return (*lanes)[lane][index];
    }

    Vector!(T, N) toVector() const {
        Vector!(T, N) result;
        foreach (i; 0 .. N)
            result.vector[i] = (*lanes)[i][index];
        return result;
    }

    alias toVector this;

    void opAssign(Vector!(T, N) value) {
        foreach (i; 0 .. N)
            (*lanes)[i][index] = value.vector[i];
    }

    void opAssign(vecv rhs) {
        foreach (i; 0 .. N)
            (*lanes)[i][index] = rhs.component(i);
    }

    Vector!(T, N) opCast(TT : Vector!(T, N))() const {
        return toVector();
    }

    void opOpAssign(string op)(Vector!(T, N) rhs)
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        auto lhs = toVector();
        mixin("lhs " ~ op ~ "= rhs;");
        opAssign(lhs);
    }

    auto opBinary(string op)(Vector!(T, N) rhs) const
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        auto lhs = toVector();
        mixin("lhs = lhs " ~ op ~ " rhs;");
        return lhs;
    }

    auto opBinaryRight(string op)(Vector!(T, N) lhs) const
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        auto rhs = toVector();
        mixin("lhs = lhs " ~ op ~ " rhs;");
        return lhs;
    }

    static if (N > 0) @property ref T x() { return component(0); }
    static if (N > 1) @property ref T y() { return component(1); }
    static if (N > 2) @property ref T z() { return component(2); }
    static if (N > 3) @property ref T w() { return component(3); }
}

/// Const view variant.
struct vecvConst(T, size_t N) {
    alias VectorType = Vector!(T, N);
    private const(T[][N])* lanes;
    private size_t index;

    this(ref T[][N] storage, size_t idx) @trusted {
        this(&storage, idx);
    }

    this(ref const(T[][N]) storage, size_t idx) {
        this(&storage, idx);
    }

    this(const(T[][N])* storage, size_t idx) {
        lanes = storage;
        index = idx;
    }

    const(T) component(size_t lane) const {
        assert(lanes !is null, "vecvConst is not bound to storage");
        return (*lanes)[lane][index];
    }

    Vector!(T, N) toVector() const {
        Vector!(T, N) result;
        foreach (i; 0 .. N)
            result.vector[i] = (*lanes)[i][index];
        return result;
    }

    alias toVector this;

    static if (N > 0) @property const(T) x() const { return component(0); }
    static if (N > 1) @property const(T) y() const { return component(1); }
    static if (N > 2) @property const(T) z() const { return component(2); }
    static if (N > 3) @property const(T) w() const { return component(3); }
}

alias Vec2Array = veca!(float, 2);
alias Vec3Array = veca!(float, 3);
alias Vec4Array = veca!(float, 4);

alias vec2v = vecv!(float, 2);
alias vec3v = vecv!(float, 3);
alias vec4v = vecv!(float, 4);

alias vec2vConst = vecvConst!(float, 2);
alias vec3vConst = vecvConst!(float, 3);
alias vec4vConst = vecvConst!(float, 4);

template VecArray(T, size_t N) {
    alias VecArray = veca!(T, N);
}

veca!(T, N) vecaFromVectors(T, size_t N)(const Vector!(T, N)[] data) {
    return veca!(T, N)(data.dup);
}

Vector!(T, N)[] toVectorArray(T, size_t N)(const veca!(T, N) storage) {
    return storage.toArray();
}

private bool isSIMDCompatible(T)() {
    static if (isFloatingPoint!T || (isIntegral!T && (T.sizeof == 2 || T.sizeof == 4 || T.sizeof == 8)))
        return true;
    else
        return false;
}

private bool canApplySIMD(T)(const T[] dst, const T[] src) {
    if (dst.length != src.length) {
        return false;
    }
    if (dst.length == 0) {
        return true;
    }
    enum mask = simdAlignment - 1;
    auto dstPtr = cast(size_t)dst.ptr;
    auto srcPtr = cast(size_t)src.ptr;
    return ((dstPtr | srcPtr) & mask) == 0;
}

private @trusted void applySIMD(string op, T)(ref T[] dst, const T[] src)
if (isSIMDCompatible!T) {
    enum width = 16 / T.sizeof;
    alias VectorType = __vector(T[width]);

    size_t i = 0;
    for (; i + width <= dst.length; i += width) {
        auto a = *cast(VectorType*)(dst.ptr + i);
        auto b = *cast(VectorType*)(src.ptr + i);
        static if (op == "+")
            a += b;
        else static if (op == "-")
            a -= b;
        else static if (op == "*")
            a *= b;
        else
            a /= b;
        *cast(VectorType*)(dst.ptr + i) = a;
    }
    for (; i < dst.length; ++i) {
        static if (op == "+")
            dst[i] += src[i];
        else static if (op == "-")
            dst[i] -= src[i];
        else static if (op == "*")
            dst[i] *= src[i];
        else
            dst[i] /= src[i];
    }
}

unittest {
    alias Vec = veca!(float, 3);
    Vec storage;
    storage.ensureLength(2);
    storage[0] = Vector!(float, 3)(1, 2, 3);
    storage[1] = Vector!(float, 3)(4, 5, 6);

    auto copy = storage.toArray();
    assert(copy.length == 2);
    assert(copy[0][0] == 1 && copy[1][2] == 6);

    auto view = storage[0];
    view.x += 2;
    view.y = 10;
    storage += storage;
    assert(approxEqual(storage[0].x, (1 + 2) * 2));
    assert(approxEqual(storage[1].z, 12));

    Vector!(float, 3) vec = storage[0];
    assert(vec[0] == storage[0].x);
    vec[1] = 2;
    storage[0] = vec;
    assert(approxEqual(storage[0].y, 2));

    storage ~= Vector!(float, 3)(7, 8, 9);
    auto concatenated = storage ~ Vector!(float, 3)(0, 0, 0);
    assert(concatenated.length == storage.length + 1);

    float sumBefore;
    foreach (ref elem; storage) {
        sumBefore += elem.x;
        elem.x += 1;
    }
    assert(sumBefore > 0);

    auto dupe = storage.dup;
    assert(dupe.length == storage.length);

    auto rebuilt = vecaFromVectors!(float, 3)(storage.toArray());
    assert(rebuilt.length == storage.length);

    Vec2Array arr2;
    arr2 ~= Vector!(float, 2)(1, 1);
    arr2 ~= Vector!(float, 2)(2, 2);
    assert(arr2.length == 2);
}
