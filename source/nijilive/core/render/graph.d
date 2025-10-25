module nijilive.core.render.graph;

import nijilive.core.nodes;
import nijilive.core.render.scheduler;

/// Manages task graph construction and execution per Puppet.
class RenderGraph {
private:
    TaskScheduler scheduler_;

public:
    this() {
        scheduler_ = new TaskScheduler();
    }

    void buildFrame(Node root) {
        scheduler_.clearTasks();
        if (root !is null) {
            scheduleNode(root);
        }
    }

    void execute(ref RenderContext ctx) {
        scheduler_.execute(ctx);
    }

    TaskScheduler scheduler() { return scheduler_; }

private:
    void scheduleNode(Node node) {
        node.registerRenderTasks(scheduler_);
    }
}
