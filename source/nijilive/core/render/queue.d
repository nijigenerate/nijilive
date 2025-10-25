module nijilive.core.render.queue;

import nijilive.core.render.commands;

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
