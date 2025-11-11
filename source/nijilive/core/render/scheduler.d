module nijilive.core.render.scheduler;

import std.array : array;
import std.range : iota;

/// Execution order for node tasks.
enum TaskOrder : int {
    Init = 1,
    Parameters = 2,
    PreProcess = 3,
    Dynamic = 4,
    Post0 = 5,
    Post1 = 6,
    Post2 = 7,
    RenderBegin = 8,
    Render = 9,
    RenderEnd = 10,
    Final = 11,
}

/// Classification used mainly for debugging/logging.
enum TaskKind {
    Init,
    Parameters,
    PreProcess,
    Dynamic,
    PostProcess,
    Render,
    Finalize,
}

import nijilive.core.render.queue;
import nijilive.core.render.graph_builder;
import nijilive.core.render.backends : RenderingBackend, BackendEnum, RenderGpuState;

alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);

/// Context shared by task handlers for per-frame data.
struct RenderContext {
    RenderQueue* renderQueue;
    RenderGraphBuilder* renderGraph;
    RenderBackend renderBackend;
    RenderGpuState gpuState;
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
        orderSequence = [TaskOrder.Init, TaskOrder.Parameters,
                         TaskOrder.PreProcess, TaskOrder.Dynamic,
                         TaskOrder.Post0, TaskOrder.Post1, TaskOrder.Post2,
                         TaskOrder.RenderBegin, TaskOrder.Render, TaskOrder.RenderEnd,
                         TaskOrder.Final];
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
