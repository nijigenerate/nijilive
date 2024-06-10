module nijilife.core.nodes.part.apart;
import nijilife.core.nodes.part;
import nijilife.core;
import nijilife.math;

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