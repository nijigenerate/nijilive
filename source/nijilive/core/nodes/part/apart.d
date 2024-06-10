module nijilive.core.nodes.part.apart;
import nijilive.core.nodes.part;
import nijilive.core;
import nijilive.math;

/**
    Parts which contain spritesheet animation
*/
@TypeId("AnimatedPart")
class AnimatedPart : Part {
private:

protected:
    override
    string typeId() { return "AnimatedPart"; }

public:

    /**
        The amount of splits in the texture
    */
    vec2i splits;
}