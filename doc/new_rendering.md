# 新レンダリングパイプライン設計案

## 目的

既存の `beginUpdate → update → endUpdate` 方式は、親→子の再帰と `preProcess` / `postProcess` の副作用が絡み合うため、どの処理がいつ動くのか可視性が低い。そこで以下の方針で順序を明示的に管理する。

~~~mermaid
flowchart LR
    A[Node Tree Traverse<br/>親→子で1回] --> B[TaskQueue Order 1..N 登録]
    B --> C[Order 1..N の順番で TaskQueue 実行<br/>CPU側で計算完了]
    C --> D[GPUQueue に描画コマンドを enqueue]
    D --> E[flush（GPUQueue） GPU描画]
~~~

1. 実行順序番号 `Order[1..N]` を定義し、各順序に対応するコマンドキュー `TaskQueue[Order]` を用意する。
2. GPU バックエンド専用のキュー `GPUQueue` を用意し、描画 API 呼び出しはすべてここに集約する。
3. ノードツリーを親→子で1度だけトラバースし、各ノードが必要とする処理を `TaskQueue` へ登録する。
4. 各 `Order` ごとに `TaskQueue[Order]` を順番に処理する。CPU 計算はこのステージで実行し、GPU 呼び出しは **バックエンド専用モジュールが提供する API** を通じて `GPUQueue` にコマンドとして積む。
5. 実際のレンダリングパスでは `GPUQueue` を順次実行するだけにし、描画 API の順序・同期を統一管理する。

これにより「いつ何が動くか」を明示しつつ、CPU 側と GPU 側の責務を分離できる。

---

## キュー構造

    TaskQueue[1] :  beginUpdate 相当（状態初期化、キャッシュ無効化 等）
    TaskQueue[2] :  前処理（デフォーマ設定、translateChildren 等）
    TaskQueue[3] :  拡張ステージ（Physics, Driver 更新 等）
    TaskQueue[4] :  後処理（postProcess、通知フラッシュ 等）
    TaskQueue[5] :  RenderBegin（親ノードが BeginComposite/BeginMask などを enqueue）
    TaskQueue[6] :  Render（Drawable が描画コマンドを生成）
    TaskQueue[7] :  RenderEnd（親ノードが EndComposite/EndMask を enqueue）
    ...
    GPUQueue     :  描画 API 呼び出しのみ

~~~mermaid
flowchart TB
    Q1[TaskQueue 1<br/>beginUpdate相当]
    Q2[TaskQueue 2<br/>前処理]
    Q3[TaskQueue 3<br/>拡張ステージ（Physics, Driver）]
    Q4[TaskQueue 4<br/>後処理（postProcess）]
    Q5[TaskQueue 5<br/>RenderBegin]
    Q6[TaskQueue 6<br/>Render]
    Q7[TaskQueue 7<br/>RenderEnd]
    GPU[GPUQueue<br/>描画API呼び出しのみ]
    Q1 --> Q2 --> Q3 --> Q4 --> Q5 --> Q6 --> Q7 --> GPU
~~~

- `TaskQueue` の要素は `{ Node node; TaskKind kind; void delegate(Context) handler; }` のような構造体を想定。`Context` には現在の `Puppet`、時間情報、共有バッファなどを渡す。
- `TaskKind` はログ出力や可視化のための分類（例: `Init`, `PreDeform`, `Physics`, `Post`, `Render`）。
- `GPUQueue` の要素は `{ BackendCommand cmd; BackendPayload payload; }`。`BackendCommand` は OpenGL/Vulkan 等の抽象化で、実装は `nijilive.backend.opengl`, `nijilive.backend.metal` など backend 固有モジュールに閉じ込める。

---

## ノードトラバースとタスク登録

~~~mermaid
sequenceDiagram
    participant R as Puppet Root
    participant DFS as DFS(親→子)
    participant N as Node
    participant TQ as TaskQueue
    DFS->>R: 開始
    loop 親→子で1回
        DFS->>N: executionOrders() の取得
        DFS->>TQ: TaskQueue[orderId] へ登録
    end
~~~

1. Puppet のルートから DFS で親→子へ1パス走査し、各ノードが必要とするタスクを登録する。
2. 各ノードは「自分が必要とする実行順序」を宣言（例: `Node.executionOrders()` が `OrderSpec[]` を返す）。
   ```d
   struct OrderSpec {
       int orderId;                 // 1..N
       TaskKind kind;
       void delegate(Node, Context) producer; // TaskQueue に入れる処理
   }
   ```
3. トラバース中に `producer` を呼び、`TaskQueue[orderId]` へタスクを登録する。
   - 例: GridDeformer は `orderId=2` の `PreDeform` タスク（子ノードの translateChildren 設定）と、`orderId=3` の `DynamicDeform` タスク（dynamic=true の場合の post 変形）を登録。
   - MeshGroup は `orderId=2` で `filterChildren`、`orderId=3` で `dynamic` 時の再計算を登録。
   - Drawable は `orderId=4` で最終的な描画命令生成タスクを登録し、ここで GPU コマンドを enqueue する。
4. 子ノードの登録は親より後に必ず並ぶので、順序情報は `orderId` とキューの FIFO 性で保証される。

---

## タスク実行フェーズ

~~~mermaid
sequenceDiagram
    participant EX as Executor
    participant T1 as TaskQueue[1]
    participant T2 as TaskQueue[2]
    participant T3 as TaskQueue[3]
    participant T4 as TaskQueue[4]
    participant GQ as GPUQueue
    EX->>T1: 順番に実行
    T1-->>GQ: enqueue (必要時)
    EX->>T2: 次へ
    T2-->>GQ: enqueue (必要時)
    EX->>T3: 次へ
    T3-->>GQ: enqueue (必要時)
    EX->>T4: 次へ
    T4-->>GQ: enqueue (必要時)
~~~

各 `orderId` について以下を繰り返す。

    for orderId in 1..N:
        foreach task in TaskQueue[orderId]:
            task.handler(context);              // CPU 計算をここで完結させる
            if (task で GPU 呼び出しが必要)
                backend.enqueue(GPUQueue, task.toBackendCommand())

- CPU 側で座標や行列、デフォーマのキャッシュ、物理演算等をすべて解決し、GPU が必要とする頂点/Uniform/Texture はここで確定させる。
- OpenGL などの API 直接呼び出しは禁じ、バックエンド共通の `backend.enqueue` を経由する。この関数は backend 固有モジュールにのみ定義する（例: `nijilive.backend.opengl.enqueueDraw(meshId, uniforms)`）。

---

## GPUQueue 実行フェーズ

~~~mermaid
sequenceDiagram
    participant BE as backend
    participant GQ as GPUQueue
    BE->>GQ: flush()
    GQ-->>BE: コマンドを順次取得
    BE-->>BE: OpenGL / Vulkan / Metal などに変換・実行
~~~

描画前の最終ステップとして

backend.flush(GPUQueue);

を呼ぶ。`flush` は backend 固有実装（OpenGL, Metal, Vulkan...）が `GPUQueue` の内容を順番に `glBindBuffer`, `vkCmdDraw` 等へ変換して送出する。この段階では CPU 側の状態更新は行わず、描画専用コマンドのみが流れる。

### Maskコマンドの分解

- `BeginMask` … ステンシルバッファのクリアと enable/disable だけを担当。親ノード（Part/Composite）が RenderBegin で enqueue。
- `ApplyMask` … `MaskApplyPacket`（`MaskDrawableKind` + `PartDrawPacket` or `MaskDrawPacket`）を保持し、Backend で `glColorMask(GL_FALSE, ...)` → mask geometry draw → `glColorMask(GL_TRUE, ...)` の順序を一箇所に閉じ込める。
- `BeginMaskContent` / `EndMask` … `glStencilFunc(GL_EQUAL, …)` と `glStencilMask(0x00)` / reset を行う。以降の `DrawPart` / `DrawCompositeQuad` が自動的にマスクされる。

RenderQueue 上では `BeginMask → ApplyMask×N → BeginMaskContent → DrawXXX → EndMask` という並びを保証し、Backend 側では `MaskApplyPacket.isDodge` を見て `glStencilFunc(GL_ALWAYS, 0|1, 0xFF)` を切り替える。Mask ノード自身は `MaskDrawPacket` を組み立てるだけで GL 呼び出しを持たないため、将来的に別 Backend へ差し替えても CPU 側変更は不要。

### DynamicComposite の描画

- `BeginDynamicComposite` … DynamicComposite ノードがオフスクリーン描画を要求した時に enqueue。Backend 側で RenderTarget スタックへ push し、FBO/Viewport を差し替えてクリアする。
- 子 Part/Composite は DynamicComposite が flatten 済みの `subParts` を走査して `PartDrawPacket` を enqueue。CPU 側では `withChildRenderTransform` で Camera/Transform を一時的に差し替える。
- `EndDynamicComposite` … push した RenderTarget を pop し、元の FBO/Viewport へ戻してテクスチャの mipmap を更新する。

---

## 既存パイプラインからのマッピング

| 旧フェーズ                        | 新設計での `orderId` | 備考 |
|----------------------------------|----------------------|------|
| `beginUpdate`                    | 1 (`TaskKind.Init`)  | 状態初期化・キャッシュクリア。 |
| `preProcess`                    | 2 (`PreDeform`)       | 親→子の順序を維持。|
| `deformStack.update`, ドライバ、物理 | 3 (`Dynamic/Physics`) | 変形や physics をここで計算。 |
| `postProcess` / `endUpdate`      | 4 (`Post`)           | 通知フラッシュや描画準備。 |
| 描画 (`draw`, OpenGL 呼び出し)   | `GPUQueue`           | ここでは CPU 側計算無し。 |

---

## バックエンド実装の分離

~~~mermaid
classDiagram
    class BackendCore{
      enqueue()
      flush()
    }
    class OpenGLBackend
    class VulkanBackend
    class MetalBackend
    BackendCore <|-- OpenGLBackend
    BackendCore <|-- VulkanBackend
    BackendCore <|-- MetalBackend
~~~

- `nijilive.backend.core` : `GPUQueue`, `BackendCommand`, `BackendPayload` の定義と enqueue/flush API。
- `nijilive.backend.opengl`, `nijilive.backend.vulkan`, ... : `BackendCommand` に対する具体的な API 呼び出し列を実装。
- Node/Deformer 側は backend 具体実装に触れず、`backend.enqueueDraw(drawArgs)` などの抽象 API を呼ぶだけとする。こうすることで描画 API を差し替えやすくし、CPU 側計算ロジックとの依存を断つ。

---

## 実装ステップの提案

1. `TaskQueue` / `GPUQueue` / `BackendCommand` の基盤となるモジュールを追加。
2. Node に `OrderSpec[] executionOrders()` を追加し、既存の `preProcessFilters` / `postProcessFilters` を順次置き換える。
3. ルートトラバース (`collectTasks`) を実装し、`Puppet.update` から呼び出す。
4. `TaskQueue` 実行ループと `GPUQueue` flush を既存の update パイプラインの代わりに組み込む。
5. レガシーコードから直接 OpenGL を呼んでいる箇所を Backend API 呼び出しに移行。

この設計により、どの処理がどこで実行されるかが `TaskQueue` / `orderId` / `GPUQueue` で明示され、デバッガやプロファイラでも追跡しやすくなる。また、処理の挿入・順序変更・非同期化の余地が広がり、バックエンド差し替えも容易になる。

---

## RenderBackend/API 実装ガイドライン

実装段階で判明した注意点を以下にまとめる。新規 Backend を追加する際や Node を拡張する際は必ず確認すること。

1. **Backend は `RenderCommandKind` を完全に網羅すること**  
   - OpenGL 実装では `nijilive.core.render.backends.opengl.package` が `RenderBackend` を実装し、
     `DrawPart` → `glDrawPartPacket`、`BeginMask` → `inBeginMask` 等へマッピングしている。
   - 別 Backend を実装する場合は、同等のモジュール分割（`part_resources.d` / `mask_resources.d` など）を行い、
     リソース初期化を `ensure...Initialized()` 形式で遅延実行にする。

2. **Node 側から直接 OpenGL を呼ばない**  
   - Part／Mask／Composite などのノードは `runRenderTask` / `runRenderBeginTask` / `runRenderEndTask` 内で
     RenderQueue に CPU パラメータを詰めるだけとし、GL 呼び出しは行わない。
   - 互換 API (`drawOneImmediate` など) を実装する場合も、新しい RenderQueue をその場で作成し、
     `RenderBackend` へ flush して再利用する。

3. **ユニットテスト向けのスタブ**  
   - `version(unittest)` では OpenGL リソースを生成せずに済むスタブを提供する。
     例：`nijilive.core.render.backends.opengl.texture_backend` は単体テスト時に GL ハンドルを 0 で返す。
   - RenderQueue のスナップショットテストを追加する場合は、`RecordingBackend` のような
     モック Backend を用意し、`RenderCommandKind` の列を検証する。

4. **マスクとコンポジットの整合性**  
   - `BeginMask` → `ApplyMask` → `BeginMaskContent` → `DrawXXX` → `EndMask` の並びを守る。
     ノード側では `MaskBinding` の解決と `MaskDrawableKind` の指定だけを行い、
     Backend でステンシル操作を完結させる。
   - Composite／DynamicComposite は `BeginComposite`／`BeginDynamicComposite` と
     `DrawCompositeQuad`／`EndDynamicComposite` を対にする。RenderQueue の順序保証を前提に実装すること。

5. **CPU-only ノードの扱い**  
   - MeshGroup／GridDeformer／PathDeformer などは GPU コマンドを出さない。
     これらの Node が RenderQueue にコマンドを積んでいないか、スナップショットテストで確認する。

以上を守ることで、RenderQueue ベースの新パイプラインを安全に拡張できる。
