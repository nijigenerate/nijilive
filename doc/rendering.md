# Current Rendering Pipeline (TaskScheduler / RenderQueue)

This document captures the rendering pipeline that is already implemented in the repository as of 2025-03.  
Some parts of the feature set are still WIP, but the goal here is to record the behaviour that actually runs today
and to visualise how TaskScheduler, RenderQueue, and the Node tree interact.

---

## 1. High-Level Flow

- `Puppet.update()` drives a frame and registers the entire node tree into the TaskScheduler.
- The TaskScheduler executes a fixed `TaskOrder` sequence and, during render phases, accumulates GPU commands in the RenderQueue.
- `RenderGraphBuilder` keeps separate `RenderPass` entries for Root / DynamicComposite targets, then sorts commands
  by `zSort` (descending) and submission order before forwarding them to the backend.
- DynamicComposite nodes declare scopes via `pushDynamicComposite/popDynamicComposite`, confining child drawing into their own FBOs before handing them to the parent target. MaskingとDynamicComposite再描画判定もこのスコープで処理する。

```mermaid
graph TD
    A["Puppet.update()"] --> B["renderGraph.beginFrame()"]
    B --> C["rootNode.registerRenderTasks()"]
    C --> D["TaskScheduler queues (TaskOrder)"]
    D --> E["TaskScheduler.executeRange(...)"]
    E --> F["Node runRender* handlers"]
    F --> G["RenderGraph enqueue / push-pop"]
    G --> H["RenderPass stack (Root / Dynamic)"]
    H --> I["Puppet.draw() -> renderGraph.playback(commandEmitter)"]
    I --> J["Emitter/Backend draws"]
```

---

## 2. TaskScheduler

### 2.1 Data Structures

- Implementation: `source/nijilive/core/render/scheduler.d`
- `TaskScheduler` stores `Task[][TaskOrder] queues` and iterates the fixed
  `orderSequence = [Init, Parameters, PreProcess, Dynamic, Post0, Post1, Post2, Final, RenderBegin, Render, RenderEnd]`.
- A `Task` is `(TaskOrder order, TaskKind kind, TaskHandler handler)`.  
  `TaskHandler` is `void delegate(ref RenderContext)` and `RenderContext` embeds a `RenderGraphBuilder*`,
  a `RenderBackend`, and the `RenderGpuState`.

### 2.2 Node Registration Walk

- Every `Node` exposes `registerRenderTasks` and registers itself plus its children via DFS.
  - The child list is duplicated and **stable-sorted by `zSort` descending**, so tasks always register back-to-front.
  - Each node pushes one task per order from Init through Final. DynamicComposite overrides the render-phase entries to manage RenderQueue scopes.
  - Subtrees beneath a `DynamicComposite` ancestor may skip their own Render tasks (`allowRenderTasks=false`)
    because the parent DynamicComposite renders or reuses them offscreen.
- `Puppet.update()` orchestrates:
  1. Conditionally rebuild cached task queues (`rebuildRenderTasks`) when forced/structure-dirty
  2. Execute `TaskOrder.Init .. TaskOrder.Parameters`
  3. Rebuild-and-rerun Init/Parameters if structure changed during that stage
  4. Call `renderGraph.beginFrame()`
  5. Execute `TaskOrder.PreProcess .. TaskOrder.Final`

### 2.3 Execution Stages

1. **Init** -> `runBeginTask`: reset per-node state, offsets, caches.
2. **Parameters** -> puppet-level task updates parameters and drivers.
3. **PreProcess / Dynamic / Post0-2** -> geometry and state transitions.
4. **Final** -> `runFinalTask`: flush notifications and carry state into the next frame.
5. **Draw playback phase** -> `Puppet.draw()` calls `renderGraph.playback(commandEmitter)`, which invokes part/mask/dynamic-composite emitter operations.

### 2.4 Example Order Produced by DFS

- `registerRenderTasks` adds `TaskOrder.Init..Final` in **pre-order (parent →children)** and appends
  `TaskOrder.RenderEnd` only after all descendants finished, making RenderEnd a **post-order (children →parent)** entry.
- Because children are `zSort`-sorted, the queues inherit the same back-to-front order.
- Nodes directly under a DynamicComposite skip their own `RenderBegin/Render/RenderEnd` when `allowRenderTasks=false`.

| TaskOrder                                                      | Parent/Child order | Notes |
|----------------------------------------------------------------|--------------------|-------|
| Init / PreProcess / Dynamic / Post0-2 / RenderBegin / Render / Final | Parent →child (pre-order) | Parent task goes first, followed by children sorted by `zSort` |
| RenderEnd                                                      | Child →parent (post-order) | Registered after the parent finishes registering its children |

Example: Root →Composite →PartA/B (B has higher `zSort`):

```mermaid
graph TD
    Root((Root)) --> Comp((Composite))
    Comp --> PartA((Part A))
    Comp --> PartB((Part B))
```

- `TaskQueue[Render] = [Root, Composite, PartB, PartA]`
- `TaskQueue[RenderEnd] = [PartA, PartB, Composite, Root]`

This queue order is exactly how `TaskScheduler.execute` invokes the handlers, which in turn manipulate RenderQueue via `RenderContext`.

---

## 3. RenderQueue / RenderGraphBuilder

### 3.1 Layered RenderPasses

- Implementation: `source/nijilive/core/render/graph_builder.d`
- `RenderGraphBuilder` keeps a `passStack`; `RenderPassKind` is `Root / DynamicComposite`.
- Each pass stores `RenderItem[] items` with `(zSort, sequence, RenderCommandBuilder builder)`.  
  The builder is a closure that accepts a `RenderCommandEmitter` and issues the required calls.
  `sequence` increments monotonically per pass to maintain stability when `zSort` ties.
- `RenderScopeHint` chooses which pass receives an item. Nodes walk ancestors to find active
  DynamicComposite scopes. DynamicComposites that reuse cached textures return `skipHint`
  so their children do not enqueue new commands.

### 3.2 Enqueue and Sorting

- `enqueueItem(float zSort, RenderScopeHint hint, builder)` stores the delegate for later playback.
- `collectPassItems` sorts each pass by `zSort` descending then by `sequence` ascending and returns
  the ordered list of builders.

### 3.3 DynamicComposite Scopes

- `dynamicRenderBegin` decides whether the DynamicComposite needs a redraw. If yes:
  - call `pushDynamicComposite`
  - rewrite child parts Emodel matrices for the offscreen basis
  - enqueue each child (nested DynamicComposite may recurse)
- `dynamicRenderEnd`:
  - `popDynamicComposite(token, this, postCommands)` to emit `BeginDynamicComposite →child →EndDynamicComposite`
  - `postCommands` typically draw the DynamicComposite as a Part, including masks
  - if no redraw happened, fall back to `enqueueRenderCommands`
- After closing, it resets `dynamicScopeActive` / `dynamicScopeToken` and updates cache flags (`textureInvalidated`, `deferred`, etc.).

### 3.5 Playback and Backend Handoff

- `playback(RenderCommandEmitter emitter)` enforces balanced scopes (`passStack.length == 1`), sorts Root pass items,
  emits command builders, then clears the graph for the next frame.
- The emitter implementation decides handoff style:
  - OpenGL emitter (`backends/opengl/queue.d`) dispatches backend draw APIs directly.
  - Queue backend emitter (`CommandQueueEmitter`) records `QueuedCommand[]`.

```mermaid
sequenceDiagram
    participant Scope as "pushDynamicComposite/popDynamicComposite API"
    participant Pass as "RenderPass stack"
    participant Sort as "zSort sorter"
    participant Backend as "RenderBackend"
    Scope->>Pass: pushDynamicComposite
    Pass->>Pass: accumulate child RenderItems
    Scope->>Pass: popDynamicComposite
    Pass->>Sort: finalize*Pass →flatten child commands
    Sort->>Pass: merge into parent pass (zSort desc + sequence)
    Pass->>Backend: playback() -> emitter issues RenderCommandKind operations
```

---

## 4. How TaskScheduler and RenderQueue Cooperate

### 4.1 Two Queues, One Flow

1. **Scheduling (TaskScheduler)**  
   - DFS over the node tree enqueues handlers into `TaskQueue[TaskOrder]`.  
     Only the execution order is decided at this point; no GPU commands exist yet.
2. **Execution -> RenderGraph updates**  
   - `TaskScheduler.executeRange(...)` walks the scheduled stage ranges used by `Puppet.update()`.  
     Render-related handlers call `pushDynamicComposite/popDynamicComposite` and `enqueueItem`, using the `RenderGraphBuilder*` in `RenderContext`.
   - RenderGraphBuilder accumulates `RenderPass` stacks and `RenderItem`s while keeping the original `zSort` ordering.
3. **RenderGraph playback -> Emitter/Backend**  
   - In `Puppet.draw()`, `renderGraph.playback(commandEmitter)` emits the final render operations.
   - Backend work is immediate (OpenGL emitter) or recorded (queue backend emitter).

```mermaid
sequenceDiagram
    participant Tree as "Node tree"
    participant TaskQ as "TaskScheduler queues"
    participant RenderGraph as "RenderGraphBuilder"
    participant Stack as "RenderPass stack"
    participant Backend
    Tree->>TaskQ: registerRenderTasks (DFS / zSort)
    TaskQ->>RenderGraph: runRenderBegin (push scope / set hints)
    TaskQ->>RenderGraph: runRenderTask (enqueue commands)
    TaskQ->>RenderGraph: runRenderEnd (pop scope / finalize)
    RenderGraph->>Stack: RenderItems kept per scope
    Stack->>Backend: playback() sends RenderCommandKind stream via emitter
    Backend-->>Tree: state reset for the next frame
```

### 4.2 Step-by-Step Recap

1. **Tree Scan & Preparation**  E`scanParts` gathers drivers/parts; DynamicComposite prepares local ordering and offscreen transforms.
2. **TaskScheduler Enqueue**  E`registerRenderTasks` pushes handlers into queues (`RenderEnd` in post-order).
3. **TaskOrder Execution** -> `TaskScheduler.executeRange` runs stage handlers and computes `RenderScopeHint` for renderable nodes.
4. **RenderGraph Stack Ops** -> `pushDynamicComposite` opens scopes; `enqueueItem` appends commands; `pop*` finalizes and hands off to parent pass.
5. **Playback & GPU Calls** -> `Puppet.draw()` runs `renderGraph.playback(commandEmitter)` and the emitter performs backend calls (or records commands).

---

## 5. Design Guarantees Relied Upon by the Code

- **Scope integrity** -> Every `push*` must pair with a `pop*`; playback enforces `passStack.length == 1`.
- **Consistent zSort** -> Both task registration and graph item sorting respect `zSort` descending, preserving DFS relationships while ensuring back-to-front rendering.
- **Localised masks** -> `MaskApplyPacket` usage is confined to DynamicComposite transfers so child rendering remains unaffected.
- **DynamicComposite cache discipline** -> Flags like `reuseCachedTextureThisFrame` / `textureInvalidated` avoid unnecessary redraws and scope churn.
- **Backend abstraction** -> RenderGraph emits emitter operations; OpenGL-specific GPU calls live in backend/emitter implementation.

These guarantees allow the current TaskScheduler and RenderQueue implementation to produce predictable, debuggable frame output.

---

## 6. RenderBackend and RenderGpuState

### 6.1 RenderBackend interface

- Defined in `source/nijilive/core/render/backends/package.d`.
- `RenderBackend` is the abstraction used by emitters to convert render operations into actual GPU calls.
- Key method groups:

| Category | Representative methods | Purpose |
|----------|------------------------|---------|
| Initialization / viewport | `initializeRenderer`, `resizeViewportTargets`, `beginScene`, `endScene`, `postProcessScene` | Renderer setup and per-frame boundaries |
| Drawable / Part resources | `initializeDrawableResources`, `createDrawableBuffers`, `uploadDrawableIndices`, `uploadSharedVertexBuffer`, `uploadSharedUvBuffer`, `uploadSharedDeformBuffer`, `drawDrawableElements` | Mesh / vertex buffer allocation and updates |
| Blending / debug | `supportsAdvancedBlend`, `setAdvancedBlendEquation`, `issueBlendBarrier`, `initDebugRenderer`, `drawDebugLines` | Advanced blend equations and debug drawing |
| RenderQueue-derived drawing | `drawPartPacket`, `beginMask`, `applyMask`, `beginMaskContent`, `endMask` | RenderCommandKind → backend API |
| DynamicComposite | `beginDynamicComposite`, `endDynamicComposite`, `destroyDynamicComposite` | Offscreen FBO lifecycle for dynamic composites |
| Utility drawing | `drawTextureAtPart`, `drawTextureAtPosition`, `drawTextureAtRect` | Direct drawing helpers for UI/debug |
| Framebuffer / texture handles | `framebufferHandle`, `renderImageHandle`, `compositeFramebufferHandle`, ... | Allow external tooling/post-processors to access GPU resources |
| Difference aggregation | `setDifferenceAggregationEnabled`, `evaluateDifferenceAggregation`, `fetchDifferenceAggregationResult` | Automated visual-diff tooling |

From the emitter perspective, render operations call these methods in sequence, leaving API specifics to the backend implementation.

### 6.2 RenderGpuState

- Struct: `RenderGpuState { uint framebuffer; uint[8] drawBuffers; ubyte drawBufferCount; bool[4] colorMask; bool blendEnabled; }`
- Role:
  - Cache the currently bound framebuffer, draw buffers, color mask, and blend state inside the backend.
  - `commandEmitter.beginFrame(...)` resets it via `state = RenderGpuState.init;`; the backend updates the fields as it switches GPU resources.
  - Serves as a shared, API-agnostic state block so future backends (OpenGL, Vulkan, etc.) can reuse the same interface.

With this addition, the documentation now covers the RenderQueue →RenderBackend handoff and the shared state management that underpins it.

---

## 6.3 Node-to-Command Mapping Table

This section is split into three compact views:

- Node-role view (what each node emits)
- Command-kind view (which packet each command carries)
- Typical command sequence patterns

### 6.3.1 Node-role View

| Node type | Entry point | Main emitter call(s) | Primary payload |
|---|---|---|---|
| `Part` (`core/nodes/part/package.d`) | `runRenderTask` -> `enqueueRenderCommands` | `drawPart(part, false)`; optional mask block (`beginMask` -> `applyMask` -> `beginMaskContent` -> `endMask`) | `PartDrawPacket`; optional `MaskApplyPacket` |
| `Mask` (`core/nodes/mask/package.d`) | `runRenderTask` is no-op | used as source in `applyMask(maskDrawable, isDodge)` | `MaskDrawPacket` inside `MaskApplyPacket(kind=Mask)` |
| `Projectable` / `Composite` / `DynamicComposite` (`core/nodes/composite/projectable.d`, `.../composite.d`) | `runRenderBeginTask` / `runRenderEndTask` | `beginDynamicComposite` / `endDynamicComposite`; post-phase `drawPart(this, false)`; optional mask block | `DynamicCompositePass`; then `PartDrawPacket` |
| Generic `Drawable` as mask source | invoked from masking flow | `applyMask(drawable, isDodge)` | `MaskApplyPacket` (`kind=Part` or `kind=Mask`) |
| Base `Node` (non-renderable) | `registerRenderTasks` only | no render-emitter call | none |

### 6.3.2 Command-kind View (`CommandQueueEmitter`)

| Queue command kind | Produced by emitter call | Payload type |
|---|---|---|
| `DrawPart` | `drawPart(...)` | `PartDrawPacket` |
| `BeginDynamicComposite` | `beginDynamicComposite(...)` | `DynamicCompositePass` |
| `EndDynamicComposite` | `endDynamicComposite(...)` | `DynamicCompositePass` |
| `BeginMask` | `beginMask(...)` | flag (`usesStencil`) |
| `ApplyMask` | `applyMask(...)` | `MaskApplyPacket` |
| `BeginMaskContent` | `beginMaskContent()` | none |
| `EndMask` | `endMask()` | none |

### 6.3.3 Typical Sequence Patterns

| Case | Typical sequence |
|---|---|
| Plain part | `DrawPart` |
| Part with masks | `BeginMask` -> `ApplyMask`(xN) -> `BeginMaskContent` -> `DrawPart` -> `EndMask` |
| Dynamic composite | `BeginDynamicComposite` -> child commands -> `EndDynamicComposite` -> `DrawPart` |
| Nested dynamic composites | outer `BeginDynamicComposite` -> inner scope -> inner `EndDynamicComposite` -> outer `EndDynamicComposite` -> outer `DrawPart` |

### 6.3.4 Node-type Sequence Diagrams (Queue Command View)

#### Part (no mask)

Entry point:

- `runRenderTask` -> `enqueueRenderCommands`

Preconditions:

- `renderEnabled() == true`
- `ctx.renderGraph !is null`
- `determineRenderScopeHint().skip == false`

Enqueue logic:

- enqueues one item via `ctx.renderGraph.enqueueItem(...)`
- item emits `drawPart(part, false)` only

Emitted queue commands (typical):

- `DrawPart`

```mermaid
sequenceDiagram
    participant Node as Part node
    participant Graph as RenderGraphBuilder
    participant Emitter as CommandQueueEmitter
    participant Queue as QueuedCommand[]
    Node->>Graph: enqueueRenderCommands()
    Graph->>Emitter: drawPart(part, false)
    Emitter->>Queue: push DrawPart(PartDrawPacket)
```

#### Part (with masks)

Entry point:

- `runRenderTask` -> `enqueueRenderCommands`

Preconditions:

- same baseline as Part(no mask)
- deduplicated mask bindings are available (`masks.length > 0`)

Enqueue logic:

- enqueues one item via `ctx.renderGraph.enqueueItem(...)`
- inside item:
  - opens mask scope (`beginMask`)
  - emits one `applyMask` per mask binding
  - switches to content (`beginMaskContent`)
  - emits self draw (`drawPart(part, false)`)
  - closes mask scope (`endMask`)

Emitted queue commands (typical):

- `BeginMask`
- `ApplyMask` x N
- `BeginMaskContent`
- `DrawPart`
- `EndMask`

```mermaid
sequenceDiagram
    participant Node as Part node
    participant Graph as RenderGraphBuilder
    participant Emitter as CommandQueueEmitter
    participant Queue as QueuedCommand[]
    Node->>Graph: enqueueRenderCommands()
    Graph->>Emitter: beginMask(useStencil)
    Emitter->>Queue: push BeginMask
    loop each mask binding
        Graph->>Emitter: applyMask(maskSrc, isDodge)
        Emitter->>Queue: push ApplyMask(MaskApplyPacket)
    end
    Graph->>Emitter: beginMaskContent()
    Emitter->>Queue: push BeginMaskContent
    Graph->>Emitter: drawPart(part, false)
    Emitter->>Queue: push DrawPart(PartDrawPacket)
    Graph->>Emitter: endMask()
    Emitter->>Queue: push EndMask
```

#### Mask node (as mask source)

Entry point:

- invoked from another node's masking flow (`applyMask(maskDrawable, isDodge)`)

Preconditions:

- mask source drawable is valid
- `tryMakeMaskApplyPacket(...)` succeeds

Enqueue logic:

- no standalone draw enqueue from `Mask.runRenderTask`
- packetization occurs when emitter handles `applyMask(...)`

Emitted queue commands (typical):

- `ApplyMask` with `MaskApplyPacket(kind=Mask)`

```mermaid
sequenceDiagram
    participant PartFlow as Part/Composite mask flow
    participant Emitter as CommandQueueEmitter
    participant Queue as QueuedCommand[]
    PartFlow->>Emitter: applyMask(maskDrawable, isDodge)
    Emitter->>Emitter: tryMakeMaskApplyPacket(...)
    Emitter->>Queue: push ApplyMask(MaskApplyPacket(kind=Mask))
```

#### Projectable / DynamicComposite (base template)

Entry point:

- `runRenderBeginTask` -> `dynamicRenderBegin`
- `runRenderEndTask` -> `dynamicRenderEnd`

Preconditions:

- `renderEnabled() == true`
- `ctx.renderGraph !is null`
- `prepareDynamicCompositePass()` succeeds

Enqueue logic:

- begin phase opens scope via `pushDynamicComposite(...)`
- child draw/mask commands are enqueued into that dynamic scope
- end phase closes scope via `popDynamicComposite(...)`
- post-command draws self as part (`drawPart(projectable, false)`)

Emitted queue commands (typical):

- `BeginDynamicComposite`
- child command sequence
- `EndDynamicComposite`
- `DrawPart`

```mermaid
sequenceDiagram
    participant Proj as Projectable node
    participant Graph as RenderGraphBuilder
    participant Emitter as CommandQueueEmitter
    participant Queue as QueuedCommand[]
    Proj->>Graph: pushDynamicComposite(...)
    Graph->>Emitter: beginDynamicComposite(pass)
    Emitter->>Queue: push BeginDynamicComposite(DynamicCompositePass)
    loop child parts/masks
        Graph->>Emitter: child draw/mask commands
        Emitter->>Queue: push child command packets
    end
    Proj->>Graph: popDynamicComposite(...)
    Graph->>Emitter: endDynamicComposite(pass)
    Emitter->>Queue: push EndDynamicComposite(DynamicCompositePass)
    Graph->>Emitter: drawPart(projectable, false)
    Emitter->>Queue: push DrawPart(PartDrawPacket)
```

#### Composite (derived template; same baseline)

Entry point:

- `runRenderBeginTask` -> `dynamicRenderBegin` (Composite override)
- `runRenderEndTask` -> `dynamicRenderEnd` (inherited flow)

Preconditions:

- same baseline as Projectable
- plus Composite-specific offscreen basis setup for child rendering

Enqueue logic:

- opens dynamic scope via `pushDynamicComposite(...)` (same as base)
- for each child:
  - assigns offscreen model matrix
  - if child is `Projectable`, calls nested offscreen path (`renderNestedOffscreen`)
  - otherwise enqueues child commands directly
- closes scope and emits post self draw (same as base)

Emitted queue commands (typical):

- same baseline command kinds as Projectable
- difference is mainly in how child commands are prepared before enqueue

```mermaid
sequenceDiagram
    participant Comp as Composite node
    participant Graph as RenderGraphBuilder
    participant Child as Child Part/Projectable
    participant Emitter as CommandQueueEmitter
    participant Queue as QueuedCommand[]
    Comp->>Comp: dynamicRenderBegin(ctx)
    Comp->>Graph: pushDynamicComposite(...)
    loop each child
        Comp->>Child: setOffscreenModelMatrix(+optional renderMatrix)
        alt child is Projectable
            Child->>Graph: renderNestedOffscreen(ctx)
        else normal Part
            Child->>Graph: enqueueRenderCommands(ctx)
        end
    end
    Graph->>Emitter: beginDynamicComposite(pass)
    Emitter->>Queue: push BeginDynamicComposite
    Graph->>Emitter: child command playback
    Emitter->>Queue: push child commands
    Graph->>Emitter: endDynamicComposite(pass)
    Emitter->>Queue: push EndDynamicComposite
    Graph->>Emitter: drawPart(composite, false)
    Emitter->>Queue: push DrawPart(PartDrawPacket)
```

Notes:

- `RenderCommandKind.DrawMask` exists in `core/render/commands.d` but current emitters no longer emit it. Masking is represented by `ApplyMask` + `MaskApplyPacket`.
- OpenGL emitter (`core/render/backends/opengl/queue.d`) dispatches backend API calls immediately.
- Queue backend (`core/render/backends/queue/package.d`) records equivalent command kinds/payloads.

### 6.4 OpenGL Backend Flow (same template)

Entry point:

- OpenGL `RenderBackend` method entry points (called from emitter):
  - shared upload path: `uploadSharedVertexBuffer`, `uploadSharedUvBuffer`, `uploadSharedDeformBuffer`
  - draw path: `drawPartPacket`
  - dynamic composite path: `beginDynamicComposite`, `endDynamicComposite`
  - mask path: `beginMask`, `applyMask`, `beginMaskContent`, `endMask`

Preconditions:

- OpenGL backend object is active (`core/render/backends/opengl/package.d`).
- Emitter is OpenGL `RenderQueue` (`core/render/backends/opengl/queue.d`).
- Render graph playback is invoking emitter callbacks for the current frame.

Execution logic:

- `beginFrame`:
  - emitter stores backend/state pointers
  - resets `RenderGpuState`
  - uploads shared buffers only when dirty:
    - `uploadSharedVertexBuffer`
    - `uploadSharedUvBuffer`
    - `uploadSharedDeformBuffer`
- `playback`:
  - `drawPart` -> `makePartDrawPacket` -> `backend.drawPartPacket`
  - `beginDynamicComposite/endDynamicComposite` -> backend dynamic pass calls
  - mask calls forward to backend (`beginMask`, `applyMask`, `beginMaskContent`, `endMask`)
- `endFrame`:
  - clears emitter-side backend/state references

Emitted effects (OpenGL path):

- No intermediate queue array is produced in this emitter.
- Render operations are dispatched to backend APIs immediately during playback.

#### 6.4.1 Frame-level sequence (OpenGL emitter path)

```mermaid
sequenceDiagram
    participant Graph as RenderGraphBuilder
    participant Emitter as OpenGL RenderQueue emitter
    participant Backend as OpenGL RenderBackend
    Emitter->>Emitter: beginFrame(backend, gpuState)
    Emitter->>Backend: uploadShared*Buffer() [dirty only]
    Graph->>Emitter: playback callbacks
    Graph->>Emitter: draw/mask/dynamic callbacks
    Emitter->>Backend: drawPartPacket / beginDynamicComposite / endDynamicComposite / beginMask / applyMask / beginMaskContent / endMask
    Emitter->>Emitter: endFrame(backend, gpuState)
```

#### 6.4.2 OpenGL RenderBackend internal call path (per method)

##### 6.4.2.1 `drawPartPacket(ref PartDrawPacket packet)`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Part as oglExecutePartPacket
    participant GL as OpenGL API
    Caller->>Backend: drawPartPacket(packet)
    Backend->>Part: oglDrawPartPacket(packet)
    Part->>GL: glActiveTexture
    Part->>GL: glBindTexture
    Part->>GL: glBlendEquation
    Part->>GL: glBlendFunc
    Part->>GL: glDrawBuffers
    Part->>GL: glEnableVertexAttribArray
    Part->>GL: glBindBuffer
    Part->>GL: glVertexAttribPointer
    Part->>GL: glDrawElements
    Part->>GL: glDisableVertexAttribArray
```

Fallback branches inside the same method may additionally call:
`glGetIntegerv`, `glGetFloatv`, `glGetBooleanv`, `glIsEnabled`,
`glBindFramebuffer`, `glReadBuffer`, `glDrawBuffer`, `glBlitFramebuffer`,
`glViewport`, `glClearColor`, `glBlendEquationSeparate`, `glBlendFuncSeparate`,
`glColorMask`, `glEnable`, `glDisable`.

##### 6.4.2.2 `beginDynamicComposite(DynamicCompositePass pass)`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Dyn as oglBeginDynamicComposite
    participant GL as OpenGL API
    Caller->>Backend: beginDynamicComposite(pass)
    Backend->>Dyn: oglBeginDynamicComposite(pass)
    Dyn->>GL: glGenFramebuffers
    Dyn->>GL: glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING)
    Dyn->>GL: glGetIntegerv(GL_VIEWPORT)
    Dyn->>GL: glBindFramebuffer
    Dyn->>GL: glFramebufferTexture2D
    Dyn->>GL: glClear(GL_STENCIL_BUFFER_BIT)
    Dyn->>GL: glDrawBuffers
    Dyn->>GL: glViewport
    Dyn->>GL: glClearColor
    Dyn->>GL: glClear(GL_COLOR_BUFFER_BIT)
    Dyn->>GL: glActiveTexture
    Dyn->>GL: glBlendFunc
```

##### 6.4.2.3 `endDynamicComposite(DynamicCompositePass pass)`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Dyn as oglEndDynamicComposite
    participant GL as OpenGL API
    Caller->>Backend: endDynamicComposite(pass)
    Backend->>Dyn: oglEndDynamicComposite(pass)
    Dyn->>GL: glBindFramebuffer
    Dyn->>GL: glViewport
    Dyn->>GL: glDrawBuffers
    Dyn->>GL: glEndQuery
    Dyn->>GL: glGetQueryObjectui64v
```

##### 6.4.2.4 `beginMask(bool useStencil)`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Mask as oglBeginMask
    participant GL as OpenGL API
    Caller->>Backend: beginMask(useStencil)
    Backend->>Mask: oglBeginMask(useStencil)
    Mask->>GL: glEnable(GL_STENCIL_TEST)
    Mask->>GL: glClearStencil
    Mask->>GL: glClear(GL_STENCIL_BUFFER_BIT)
    Mask->>GL: glStencilMask
    Mask->>GL: glStencilFunc
    Mask->>GL: glStencilOp
```

##### 6.4.2.5 `applyMask(ref MaskApplyPacket packet)`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Mask as oglExecuteMaskApplyPacket
    participant GL as OpenGL API
    Caller->>Backend: applyMask(packet)
    Backend->>Mask: oglExecuteMaskApplyPacket(packet)
    Mask->>GL: glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE)
    Mask->>GL: glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE)
    Mask->>GL: glStencilFunc(GL_ALWAYS, dodge?0:1, 0xFF)
    Mask->>GL: glStencilMask(0xFF)
    alt packet.kind == Part
        Mask->>GL: glActiveTexture
        Mask->>GL: glBindTexture
        Mask->>GL: glDrawBuffers
        Mask->>GL: glEnableVertexAttribArray
        Mask->>GL: glBindBuffer
        Mask->>GL: glVertexAttribPointer
        Mask->>GL: glDrawElements
        Mask->>GL: glDisableVertexAttribArray
    else packet.kind == Mask
        Mask->>GL: glEnableVertexAttribArray
        Mask->>GL: glBindBuffer
        Mask->>GL: glVertexAttribPointer
        Mask->>GL: glDrawElements
        Mask->>GL: glDisableVertexAttribArray
    end
    Mask->>GL: glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE)
```

##### 6.4.2.6 `beginMaskContent()`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Mask as oglBeginMaskContent
    participant GL as OpenGL API
    Caller->>Backend: beginMaskContent()
    Backend->>Mask: oglBeginMaskContent()
    Mask->>GL: glStencilFunc(GL_EQUAL, 1, 0xFF)
    Mask->>GL: glStencilMask(0x00)
```

##### 6.4.2.7 `endMask()`

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Mask as oglEndMask
    participant GL as OpenGL API
    Caller->>Backend: endMask()
    Backend->>Mask: oglEndMask()
    Mask->>GL: glStencilMask(0xFF)
    Mask->>GL: glStencilFunc(GL_ALWAYS, 1, 0xFF)
    Mask->>GL: glDisable(GL_STENCIL_TEST)
```

##### 6.4.2.8 Shared buffer uploads (`uploadSharedVertexBuffer`, `uploadSharedUvBuffer`, `uploadSharedDeformBuffer`)

```mermaid
sequenceDiagram
    participant Caller as OpenGL emitter
    participant Backend as RenderingBackend(OpenGL)
    participant Upload as oglUploadShared*Buffer
    participant SoA as glUploadFloatVecArray
    participant GL as OpenGL API
    Caller->>Backend: uploadSharedVertexBuffer / uploadSharedUvBuffer / uploadSharedDeformBuffer
    Backend->>Upload: oglUploadShared*Buffer(data)
    Upload->>GL: glGenBuffers (if buffer == 0)
    Upload->>SoA: glUploadFloatVecArray(buffer, data, GL_DYNAMIC_DRAW, label)
    SoA->>GL: glBindBuffer(GL_ARRAY_BUFFER, buffer)
    SoA->>GL: glBufferData(GL_ARRAY_BUFFER, bytes, ptr, GL_DYNAMIC_DRAW)
```

Implementation note:

- `RenderingBackend` methods in `source/nijilive/core/render/backends/opengl/package.d` are thin delegates to `ogl*` functions.
- Actual OpenGL state changes and draw calls are implemented in:
  - `source/nijilive/core/render/backends/opengl/part.d`
  - `source/nijilive/core/render/backends/opengl/mask.d`
  - `source/nijilive/core/render/backends/opengl/dynamic_composite.d`
  - `source/nijilive/core/render/backends/opengl/drawable_buffers.d`

---

## 7. Frame-to-Frame Reuse Layer (2025-11 addendum)

The runtime now has a reuse layer that keeps TaskScheduler/RenderQueue behaviour exactly as documented above, while avoiding per-frame rebuilds when no nodes changed. This section only appends details; nothing earlier is removed or summarised.

### 7.1 Change Tracking (`NotifyReason`)

- Every `Node.notifyChange` also calls `puppet.recordNodeChange(reason)`.
- `Puppet` tracks two booleans per frame:  
  - `structureDirty` →triggered by `NotifyReason.StructureChanged` or forced rebuilds  
  - `attributeDirty` →triggered by `AttributeChanged`, `Transformed`, `Initialized`
- `consumeFrameChanges()` returns the accumulated flags and clears them for the next frame.

### 7.2 TaskScheduler Cache

- Task queues are rebuilt only when `forceFullRebuild` or `structureDirty` is set.  
  `rebuildRenderTasks()` clears queues, runs `rootNode.registerRenderTasks`, and injects the puppet-level `TaskOrder.Parameters` delegate that wraps `updateParametersAndDrivers`.
- Otherwise the previous queue contents remain valid and no DFS walk is performed.

### 7.3 Execution Order Preservation

- Even if we plan to reuse the render commands, each frame still runs `TaskOrder.Init` and `TaskOrder.Parameters` by calling `renderScheduler.executeRange(ctx, TaskOrder.Init, TaskOrder.Parameters)`.  
  This guarantees that deformable nodes reset their stacks (`runBeginTask`) before parameters and drivers push new deformations, exactly as before.
- If executing these stages introduces a structural change (for example, a driver toggles masks), the scheduler immediately rebuilds and reruns the Init+Parameters range before proceeding.

### 7.4 RenderGraph / RenderQueue Execution

- `renderGraph.beginFrame()` now occurs every update; nodes always enqueue their builders for the current frame.
- No cached command buffer exists. The emitter consumes builders immediately during `renderGraph.playback(commandEmitter)`.
- If Init+Parameters introduce structural changes the scheduler rebuilds and reruns just as before; afterwards, `TaskOrder.PreProcess … Final` executes every frame to keep dynamic content up to date.

### 7.5 Per-Frame Summary

1. (Optional) Rebuild TaskScheduler queues when structure changed.  
2. Always run Init + Parameters stages (deformation reset + parameter updates).  
3. Rebuild again if those stages introduced new structural edits.  
4. Run the remaining TaskOrders and rebuild RenderGraph.  
5. Invoke `renderGraph.playback(commandEmitter)` during `Puppet.draw()`, letting the backend-specific emitter translate node references into GPU work.

---

## 8. Struct-of-Arrays Geometry Atlases (Vec*Array + shared buffers)

Earlier versions uploaded a separate VBO per Part/Deformable whenever vertices, UVs, or deformation deltas changed. The current implementation replaces that per-object upload storm with three shared atlases backed by the `Vec*Array` Struct-of-Arrays storage. This section documents how the system works in practice.

### 8.1 Vec*Array Recap

- `nijilive.math.veca` defines `Vec2Array`, `Vec3Array`, and `Vec4Array` as fixed-lane Struct-of-Arrays buffers.  
  Internally they store contiguous “lanes E(`lane(0)`, `lane(1)`, …) for each component, which makes SIMD-friendly bulk copies possible.
- Each `Vec*Array` instance can `bindExternalStorage(storage, offset, length)`, meaning multiple logical arrays can share slices of one backing buffer without additional allocations.
- Geometry-heavy nodes (e.g. `Drawable`/`Deformable`) keep their vertex, UV, and deformation data in `Vec2Array` fields, so these can be re-bound to shared storage without changing higher-level code.

### 8.2 SharedVecAtlas and Registration

- `nijilive.core.render.shared_deform_buffer` defines three atlases (`deformAtlas`, `vertexAtlas`, `uvAtlas`).  
  Each atlas tracks a list of `Vec2Array*` bindings plus the pointer to the GPU packet field that needs the final offset.
- Lifecycle:
  1. `Drawable` constructors call `sharedDeformRegister`, `sharedVertexRegister`, and `sharedUvRegister`, passing each local `Vec2Array` and a pointer to `deformSliceOffset` / `vertexSliceOffset` / `uvSliceOffset`.
  2. The atlas rebuilds a single contiguous storage block sized to the sum of all registered lengths, copies existing data into the new layout (SoA lane copy), and calls `bindExternalStorage` so every node’s array views the shared memory.
  3. Whenever vertices/UVs/deforms change length, `shared*Resize` triggers another rebuild. Destructors invoke `shared*Unregister` to remove the entry.
- The atlas emits:
  - `shared*BufferData()` →the packed `Vec2Array` storage for the backend.
  - `shared*AtlasStride()` →total element count (used during packet construction).
  - Dirty flags (`shared*BufferDirty`, `shared*MarkDirty`, `shared*MarkUploaded`) to gate GPU uploads.

### 8.3 PartDrawPacket Offsets

- `PartDrawPacket` contains `vertexOffset`, `vertexAtlasStride`, `uvOffset`, `uvAtlasStride`, `deformOffset`, and `deformAtlasStride`.  
  These fields point into the shared atlases instead of per-part buffers.
- During packet construction each Drawable uses the offsets that the atlas wrote into `vertexSliceOffset` / `uvSliceOffset` / `deformSliceOffset`.  
  As long as the atlas does not rebuild, those offsets remain valid and no per-frame pointer fix-up is necessary.

### 8.4 Emitter beginFrame Upload Path

- At the start of emitter `beginFrame` (OpenGL `RenderQueue` emitter), it checks `sharedVertexBufferDirty`, `sharedUvBufferDirty`, and `sharedDeformBufferDirty`.  
  For each dirty atlas, it retrieves the packed `Vec2Array`, calls the backend’s `uploadShared*Buffer` functions once, and then marks the atlas as uploaded.
- Backend implementations (e.g. `opengl/drawable_buffers.d`) own a single GL buffer per attribute:
  - Created lazily via `glGenBuffers`.
  - Updated with `glUploadFloatVecArray(sharedBuffer, atlasData, GL_DYNAMIC_DRAW, "Upload*")`, which understands the SoA layout.
- Because every drawable references offsets inside the same buffer, the backend uploads shared VBOs once per frame (when dirty) instead of per drawable.

### 8.5 Dirty Tracking Integration

- Whenever a drawable mutates its `Vec2Array` (e.g. `Deformable.updateVertices`, welding, physics), it calls `shared*MarkDirty`.  
  The atlas does not need to rebuild unless the length changes, so most edits are in-place writes to the shared memory.
- Even though commands are rebuilt every frame, the atlas dirty flags still prevent redundant uploads, so the backend gets GPU-side reuse.

This atlas-based Struct-of-Arrays design is what enables the “single glBindBuffer/glBufferData per frame Ebehaviour discussed during the refactor, and should be kept in sync with any future changes to Vec*Array or the emitter packet builders.

### 8.6 Indices path (current implementation)

- `MeshData.indices` is currently `ushort[]` (not `Vec*Array`).
- On OpenGL backend, indices are still consolidated into a shared GPU index buffer:
  - implementation: `source/nijilive/core/render/backends/opengl/drawable_buffers.d`
  - `oglUploadDrawableIndices` assigns each drawable IBO handle to an `IndexRange` (`offset/count/capacity`) within `sharedIndexBuffer`
  - `oglDrawDrawableElements` binds `sharedIndexBuffer` and draws using the stored byte offset
- So the runtime already has a shared-index-buffer model (slice/range based), while vertex/uv/deform use `Vec2Array` SoA atlases.

---

## 9. Frame-to-Frame Reuse Layer (detailed breakdown)

> **Status:** Implemented in current codebase.  
> **Goal:** keep the DFS/TaskScheduler/RenderQueue flow intact while avoiding per-frame allocations when no node changed.

All sections above still describe the exact order in which tasks and RenderQueue scopes execute. The reuse layer simply decides **when we have to rebuild those structures**.

### 9.1 Change Tracking Basics

- Every `Node.notifyChange` now notifies the owning `Puppet` before bubbling up, passing through the original `NotifyReason`.
- The puppet records two booleans per frame: `structureDirty` (tree mutations, mask list edits, etc.) and `attributeDirty`
  (parameter edits, driver output, transforms). `NotifyReason.StructureChanged` flips both bits; every other reason flips `attributeDirty`.
- `Puppet.update()` calls `consumeFrameChanges()` to read and clear the flags.  
  A pending `forceFullRebuild` (e.g. after loading a puppet) also sets both bits.

### 9.2 TaskScheduler Cache

- On the first frame, or whenever `structureDirty` is seen, `rebuildRenderTasks()`:
  1. Clears TaskScheduler queues.
  2. Runs the usual `rootNode.registerRenderTasks`.
  3. Injects the puppet-level `TaskOrder.Parameters` entry that wraps `updateParametersAndDrivers`.
- When no structural change happened, the previously built queues stay intact and no DFS walk is needed.

### 9.3 Guaranteed Init + Parameter Stage

- Regardless of cache state, each frame runs `renderScheduler.executeRange(ctx, TaskOrder.Init, TaskOrder.Parameters)` at least once.
- This preserves the original behaviour where `runBeginTask` (deformation stack reset, filter state reset, notification deferral) always runs **before**
  parameters and drivers push new values into deform stacks.
- If a structural change is detected after that pass, the scheduler rebuilds and reruns `Init + Parameters` again.

### 9.4 Render Phases and Emitters

- Every frame executes the remaining TaskOrders (`PreProcess .. Final`) and rebuilds the pass stack after Init + Parameters.
- `renderGraph.playback(commandEmitter)` immediately replays the builders when `Puppet.draw()` runs; no cached buffer is stored.
- OpenGL uses the `RenderQueue` emitter, which builds the `PartDrawPacket`/`MaskApplyPacket` data on demand and calls the actual backend.

### 9.5 Rebuild Loop

Putting everything together:

1. **Maybe rebuild tasks**  Eif `forceFullRebuild` or `structureDirty`, re-register the node tree.
2. **Always run Init + Parameters**  Eensures deformation stacks see the injected parameter values.
3. **Consume change flags**  Eif a new structure change surfaced during step 2 (e.g. drivers toggled masks), rebuild again.
4. **Execute render stages**  Erun the remaining TaskOrders, let GraphBuilder capture builders, and hand them to the emitter during draw.

This layer lets the renderer skip redundant allocations and GL buffer uploads on the many frames where user input/automation leaves the node tree unchanged, without compromising the deterministic ordering and scope rules described earlier in this document.
