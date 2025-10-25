module nijilive.core.render.scheduler;

import std.array : array;
import std.range : iota;

/// Execution order for node tasks.
enum TaskOrder : int {
    Init = 1,
    PreProcess = 2,
    Dynamic = 3,
    Post0 = 4,
    Post1 = 5,
    Post2 = 6,
    Render = 7,
    Final = 8,
}

/// Classification used mainly for debugging/logging.
enum TaskKind {
    Init,
    PreProcess,
    Dynamic,
    PostProcess,
    Render,
    Finalize,
}

import nijilive.core.render.queue;

/// Context shared by task handlers for per-frame data.
struct RenderContext {
    RenderQueue* renderQueue;
    
}

alias TaskHandler = void delegate(ref RenderContext);

struct Task {
    TaskOrder order;
    TaskKind kind;
    TaskHandler handler;
}

/// Frame scheduler holding ordered task queues and the GPU queue.
class TaskScheduler {
private:
    Task[][TaskOrder] queues;
    TaskOrder[] orderSequence;
public:

    this() {
        orderSequence = [TaskOrder.Init, TaskOrder.PreProcess, TaskOrder.Dynamic,
                         TaskOrder.Post0, TaskOrder.Post1, TaskOrder.Post2,
                         TaskOrder.Render, TaskOrder.Final];
        foreach (order; orderSequence) {
            queues[order] = [];
        }
    }

    void clearTasks() {
        foreach (order; orderSequence) {
            queues[order].length = 0;
        }
    }

    void addTask(TaskOrder order, TaskKind kind, TaskHandler handler) {
        queues[order] ~= Task(order, kind, handler);
    }

    void execute(ref RenderContext ctx) {
        foreach (order; orderSequence) {
            foreach (task; queues[order]) {
                if (task.handler !is null) {
                    task.handler(ctx);
                }
            }
        }
    }

}
