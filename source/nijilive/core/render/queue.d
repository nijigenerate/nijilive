module nijilive.core.render.queue;

import nijilive.core.nodes;

interface RenderBackend {
    void drawNode(Node node);
}

abstract class RenderCommand {
    abstract void execute(RenderBackend backend);
}

final class DrawNodeCommand : RenderCommand {
    Node node;
    this(Node node) {
        this.node = node;
    }
    override void execute(RenderBackend backend) {
        if (node is null || backend is null) return;
        backend.drawNode(node);
    }
}

final class RenderQueue {
private:
    RenderCommand[] commands;
public:
    void clear() {
        commands.length = 0;
    }

    void enqueue(RenderCommand command) {
        if (command is null) return;
        commands ~= command;
    }

    void flush(RenderBackend backend) {
        foreach (command; commands) {
            command.execute(backend);
        }
        clear();
    }

    bool empty() const {
        return commands.length == 0;
    }
}

final class ImmediateRenderBackend : RenderBackend {
    override void drawNode(Node node) {
        if (node is null) return;
        node.drawOne();
    }
}
