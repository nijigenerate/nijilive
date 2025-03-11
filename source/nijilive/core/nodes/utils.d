module nijilive.core.nodes.utils;
import std.algorithm.mutation: remove;
import std.algorithm.searching;
import std.array;

T[] removeByValue(T)(T[] array, T value) {
    auto index = array.countUntil(value);
    if (index != -1) {
        return array.remove(index);
    }
    return array;
}

T[] upsert(T, bool prepend = false)(T[] array, T value) {
    auto index = array.countUntil(value);
    if (index == -1) {
        if (prepend)
            array.insertInPlace(0, value);
        else
            array ~= value;
    }
    return array;
}