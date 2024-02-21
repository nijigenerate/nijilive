module inochi2d.core.nodes.utils;
import std.algorithm.mutation: remove;
import std.algorithm.searching;

void removeByValue(T)(T[] array, T value) {
    auto index = array.countUntil(value);
    if (index != -1) {
        array.remove(index);
    }
}
