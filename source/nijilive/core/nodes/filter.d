module nijilive.core.nodes.filter;
import nijilive.core.nodes;
import nijilive.core.nodes.utils;
import nijilive.core.param;
public import std.format;

interface NodeFilter {
    void captureTarget(Node target);
    void releaseTarget(Node target);
    void dispose();
    void applyDeformToChildren(Parameter[] params, bool recursive = true);
}

mixin template NodeFilterMixin() {

    override
    void dispose() {
        foreach (t; children) {
            releaseChild(t);
        }
        children_ref.length = 0;
    }

    void _applyDeformToChildren(Node.Filter filterChildren, void delegate(vec2[]) update, bool delegate() transferCondition, Parameter[] params, bool recursive = true) {
        foreach (param; params) {
            ParameterBinding[Resource][string] trsBindings;
            void extractTRSBindings(Parameter param) {
                foreach (binding; param.bindings) {
                    trsBindings[binding.getTarget.name][binding.getTarget.target] = binding;
                }
            } 
            extractTRSBindings(param);

            void applyTranslation(Node node, Parameter param, vec2u keypoint, vec2 ofs) {
                foreach (name; ["t.x", "t.y", "r.z", "s.x", "s.y"].map!((x)=> "transform.%s".format(x))) {
                    if (name in trsBindings && node in trsBindings[name]) {
                        trsBindings[name][node].apply(keypoint, ofs);
                    }
                }
            }

            void transferChildren(Node node, int x, int y) {
                auto drawable = cast(Deformable)node;
                auto composite = cast(Composite)node;
                bool isDeformable = drawable !is null;
                bool isComposite = composite !is null && composite.propagateMeshGroup;
                bool mustPropagate = node.mustPropagate();
                if (isDeformable) {
                        int xx = x, yy = y;
                        float ofsX = 0, ofsY = 0;

                        if (x == param.axisPoints[0].length - 1) {
                            xx = x - 1;
                            ofsX = 1;
                        }
                        if (y == param.axisPoints[1].length - 1) {
                            yy = y - 1;
                            ofsY = 1;
                        }

                        applyTranslation(drawable, param, vec2u(xx, yy), vec2(ofsX, ofsY));
                        drawable.transformChanged;

                    auto vertices = drawable.vertices;
                    mat4 matrix = drawable.transform.matrix;

                    auto nodeBinding = cast(DeformationParameterBinding)param.getOrAddBinding(node, "deform");
                    auto nodeDeform = nodeBinding.values[x][y].vertexOffsets.dup;
                    Tuple!(vec2[], mat4*, bool) filterResult = filterChildren(node, vertices, nodeDeform, &matrix);
                    if (filterResult[0] !is null) {
                        nodeBinding.values[x][y].vertexOffsets = filterResult[0];
                        nodeBinding.getIsSet()[x][y] = true;
                    }
                } else if (transferCondition() && !isComposite) {
                    auto vertices = [node.localTransform.translation.xy];
                    mat4 matrix = node.parent? node.parent.transform.matrix: mat4.identity;

                    auto nodeBindingX = cast(ValueParameterBinding)param.getOrAddBinding(node, "transform.t.x");
                    auto nodeBindingY = cast(ValueParameterBinding)param.getOrAddBinding(node, "transform.t.y");
                    auto nodeDeform = [node.offsetTransform.translation.xy];
                    Tuple!(vec2[], mat4*, bool) filterResult = filterChildren(node, vertices, nodeDeform, &matrix);
                    if (filterResult[0] !is null) {
                        nodeBindingX.values[x][y] += filterResult[0][0].x;
                        nodeBindingY.values[x][y] += filterResult[0][0].y;
                        nodeBindingX.getIsSet()[x][y] = true;
                        nodeBindingY.getIsSet()[x][y] = true;
                    }

                }
                if (recursive && mustPropagate) {
                    foreach (child; node.children) {
                        transferChildren(child, x, y);
                    }
                }
            }

            void resetOffset(Node node) {
                node.offsetTransform.clear();
                node.offsetSort = 0;
                node.transformChanged();
                foreach (child; node.children) {
                    resetOffset(child);
                }
            }


            if  (auto binding = param.getBinding(this, "deform")) {

                auto deformBinding = cast(DeformationParameterBinding)binding;
                assert(deformBinding !is null);
                Node target = deformBinding.targetNode;

                for (int x = 0; x < param.axisPoints[0].length; x ++) {
                    for (int y = 0; y < param.axisPoints[1].length; y ++) {

                        resetOffset(puppet.root);

                        vec2[] deformation;
                        if (deformBinding.isSet_[x][y])
                            deformation = deformBinding.values[x][y].vertexOffsets;
                        else {
                            bool rightMost  = x == param.axisPoints[0].length - 1;
                            bool bottomMost = y == param.axisPoints[1].length - 1;
                            deformation = deformBinding.interpolate(vec2u(rightMost? x - 1: x, bottomMost? y - 1: y), vec2(rightMost? 1: 0, bottomMost? 1:0)).vertexOffsets;
                        }
                        update(deformation);

                        foreach (child; children) {
                            transferChildren(child, x, y);
                        }
                    }
                }
                param.removeBinding(binding);
            }

        }
    }
}