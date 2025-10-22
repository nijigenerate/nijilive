import std.stdio;
import nijilive.core.nodes.deformer.grid;
import nijilive.math;

void main() {
    auto gd = new GridDeformer(null);
    gd.rebuffer([
        vec2(-0.5f,-0.5f), vec2(0.5f,-0.5f),
        vec2(-0.5f,0.5f),  vec2(0.5f,0.5f)
    ]);
    gd.deformation = [vec2(0.1f,0.2f), vec2(0.3f,0.4f), vec2(0.5f,0.6f), vec2(0.7f,0.8f)];
    writeln("vertexBuffer:", gd.vertices);
    writeln("deformation:", gd.deformation);
}
