module nijilive.core.nodes.filter;
import nijilive.core.nodes;
import nijilive.core.nodes.utils;

interface NodeFilter {
    void captureTarget(Node target);
    void releaseTarget(Node target);
    void dispose();
}

mixin template NodeFilterMixin() {
    override
    void captureTarget(Node target) {
        children_ref ~= target;
        setupChild(target);
    }

    override
    void releaseTarget(Node target) {
        releaseChild(target);
        children_ref = children_ref.removeByValue(target);
    }

    override
    void dispose() {
        foreach (t; children) {
            releaseChild(t);
        }
        children_ref.length = 0;
    }
}