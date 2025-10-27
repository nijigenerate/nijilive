# 新レンダリングパイプライン再設計（RenderQueue Layered Model）

## 目的と背景

既存の TaskScheduler ベースのパイプラインは CPU 側の更新順序を明示できるものの、
GPUQueue へ積まれる描画コマンドの順序制御が弱く、以下の問題が残っていた。

- Composite / DynamicComposite などが「子ノードを先にターゲットへ描画し、その結果を親が利用する」
  という流れを保証できない。
- 同じレンダーターゲットを共有する描画オブジェクト間で zSort を正しく解決できず、
  マスクや半透明描画の順序が乱れる。

この再設計では **RenderQueue を「ターゲットごとのレイヤ構造」で構築し、各レイヤ内を zSort 降順でソート** してから
GPU へ流すモデルへ切り替える。これにより「ターゲットの切り替え → 子ノード描画 → 親ノードの合成」という流れを
強制しつつ、同一ターゲットを共有する描画アイテムの前後関係を一貫して管理できる。

---

## フレーム処理の全体像

```mermaid
flowchart TD
    A[Puppet.update] --> B[RenderGraph.buildFrame]
    B --> C[TaskScheduler.execute<br/>CPU Task Order]
    C --> D[RenderQueue Layered Collect]
    D --> E[RenderQueue.flush<br/>per-target sort + GPU]
    E --> F[Puppet.draw (fallback if empty)]
```

1. `RenderGraph.buildFrame()` が DFS でノードを巡り、TaskScheduler に各フェーズのタスクを登録する。
2. `TaskScheduler.execute()` が CPU タスクを実行する。描画フェーズでノードは **RenderQueue へ直接コマンドを押し込む代わりに、
   レイヤへアイテムとして登録** する。
3. `RenderQueue.flush()` が「ルートターゲット → 子ターゲット …」の順でレイヤを展開し、
   各レイヤ内のアイテムを **zSort 降順 (stable)** で整列してから GPU Backend に適用する。
4. Queue が空の場合は従来通り `rootParts.drawOne()` を呼ぶフォールバックが働く。

---

## RenderQueue のレイヤモデル

### RenderPass

- RenderQueue は `RenderPass` のスタックを管理する。スタックの底（root）はフレームバッファへの描画を表す。
- `RenderPass` には **RenderItem の配列** と、Composite / DynamicComposite 専用のメタデータを持たせる。

```d
enum RenderPassKind { Root, Composite, DynamicComposite }

struct RenderItem {
    float zSort;            // 描画アイテムの zSort
    size_t sequence;        // 安定ソート用のインクリメント ID
    RenderCommandData[] commands; // 実行時にそのまま backend へ渡すコマンド列
}

struct RenderPass {
    RenderPassKind kind;
    Composite composite;              // kind == Composite のとき
    DynamicComposite dynamicComposite; // kind == DynamicComposite のとき
    bool maskUsesStencil;
    MaskApplyPacket[] maskPackets;    // Composite 専用：BeginMask 前に発行する
    RenderItem[] items;
    size_t nextSequence;
}
```

### 基本操作

| 操作                          | 役割 |
|-------------------------------|------|
| `beginFrame()`                | ルートパスを初期化 (`RenderPassKind.Root`) |
| `enqueueItem(zSort, builder)` | 現在のパスに RenderItem を追加。builder は `RenderCommandData` の列を構築する |
| `pushComposite(...)`          | Composite 描画用パスをプッシュし、スコープトークンを返す |
| `pushDynamicComposite(...)`   | DynamicComposite 描画用パスをプッシュし、スコープトークンを返す |
| `popScope(token)`             | 指定トークンのパスを閉じ、子アイテムをソートして親に登録 |

### 処理フロー

1. ノードが描画フェーズに入ると、`RenderQueue` は自動で root パスを用意する。
2. Part / Mask 等の Drawable は `enqueueItem(zSort, builder)` を呼び、マスクコマンド込みのコマンド列を組み立てる。
3. Composite / DynamicComposite は `pushComposite` / `pushDynamicComposite` で子パスを開始し、
   返されたトークンをノード側で保持する。子ノードは同じパス上に RenderItem を積む。
4. Composite / DynamicComposite の `runRenderEndTask` で対応するトークンを `popScope(token)` に渡し、子パス内の RenderItem を **zSort 降順の安定ソート**
   した後で以下のコマンド列を生成する：

   ```
   [BeginMask?, ApplyMask*?, BeginMaskContent?]
   BeginComposite / BeginDynamicComposite
       (子 RenderItem たちの commands を順序通りに展開)
   EndComposite? + DrawCompositeQuad? / EndDynamicComposite
   [EndMask?]
   ```

   生成した列は親パスへ **1 アイテムとして zSort = 親 Composite の zSort** で登録される。
   これにより「子を描画 → 親で合成」という流れが保証される。
   また、`popComposite` / `popDynamicComposite` はスタック上に未処理の子スコープが残っている場合に自動で順次閉じるため、
   スケジューラの実行順序に関わらず常に **子ノード → 親ノード** の順でターゲット描画が確定する。
   自動クローズされたノードには通知が飛び、DynamicComposite の場合は `endComposite()` 相当の後処理も即座に実行される。
   スコープはトークンで識別され、トークンが一致しない場合は `RenderQueue` 側で即座に検知・エラーを報告する。

5. `flush()` 時に root パスの RenderItem を zSort 降順で整列し、順に Backend へ渡す。
   子 Composite / DynamicComposite の描画は、前段で生成した “合成済みのコマンド列” として展開される。

### zSort の扱い

- `RenderItem` 追加時は `Node.zSort()` の結果を渡す。
- ソートは `item.zSort` の降順で行い、同値の場合は `sequence`（挿入順）で安定ソートする。
- これにより **同じターゲット内では zSort の値が大きい描画ほど後段に残り、アルファブレンド前提の back-to-front 描画** が保証される。

---

## ノード別の負担

### Part / Mask / Drawable

- 既存の `enqueueRenderCommands` を `RenderQueue.enqueueItem` を用いた実装へ書き換える。
- マスクなど複数コマンドを伴う場合も builder 経由で一つの RenderItem にまとめる。
- Run-time で OpenGL を直接触る処理は引き続き Backend 側に閉じ込める。

### Composite

- `runRenderBeginTask` で `ctx.renderQueue.pushComposite(this, maskInfo)` を呼び、返されたトークンを保持しつつ子ノードが同一ターゲットに描画するパスを開始する。
- マスクに必要な `MaskApplyPacket` はこのタイミングで組み立てて渡す。
- `runRenderEndTask` で `ctx.renderQueue.popComposite(this)` を呼び、子 RenderItem をまとめたコマンド列を生成し、
  親パスへ `zSort = this.zSort()` のアイテムとして登録する。

### DynamicComposite

- `runRenderBeginTask` で `pushDynamicComposite(this)` を呼び、返されたトークンを保持したうえで RenderTarget スタックを push するコマンド列を組み立てる。
- `runRenderEndTask` で `popDynamicComposite(token, this)` を呼び、子アイテムを並べ替えた上で
  `[BeginDynamicComposite → 子コマンド列 → EndDynamicComposite]` を親パスに登録する。

### その他

- Fallback `runRenderTask`（未移行ノード向け）は `enqueueItem(zSort, builder)` を使って `DrawNode` コマンドを生成するだけの単位を作る。
- 将来的に新ノードを追加する場合も **「ターゲットを開く → 子を描画 → ターゲットを閉じて親に登録」** という枠組みに従えば良い。

---

## RenderQueue API の概要（案）

```d
class RenderQueue {
    void beginFrame();
    bool empty() const;
    void clear(); // beginFrame と同義

    void enqueueItem(float zSort, scope void delegate(ref RenderCommandBuffer) build);

    void pushComposite(Composite comp,
                       bool maskUsesStencil,
                       const MaskApplyPacket[] maskPackets);
    void popComposite(Composite comp);

    void pushDynamicComposite(DynamicComposite comp);
    void popDynamicComposite(DynamicComposite comp);

    void flush(RenderBackend backend, ref RenderGpuState state);
}
```

`RenderCommandBuffer` は単に `RenderCommandData[]` を保持し、`add(RenderCommandData)` で追記できる軽量ユーティリティ。

---

## 実装指針

1. **RenderQueue の刷新**
   - RenderPass / RenderItem / RenderCommandBuffer を導入。
   - 既存の `enqueue(RenderCommandData)` API は内部的に `enqueueItem` に委譲するラッパを残すか、完全に廃止する。
   - `clear()` 時に root パスを再生成し、スタックが空で flush に到達することがないようにする。

2. **Composite / DynamicComposite の改修**
   - `runRenderBeginTask` / `runRenderEndTask` を `push*/pop*` API 呼び出しに置き換え、個別に行っていたマスク・FBO 切り替えコマンドを RenderQueue に委譲する。
   - `selfSort()` や `subParts` の管理は引き続き Composite 側で行うが、実際の描画順序は RenderQueue のソート結果に従う。

3. **Part / Mask / その他 Drawable の更新**
   - `enqueueRenderCommands` を `enqueueItem` ベースへ書き換え、zSort を必ず渡す。
   - 同一ターゲットの描画順制御を queue に任せるため、呼び出し側での zSort 並べ替えロジック（例: `selfSort` のみで完結していた箇所）との整合を確認する。

4. **動作確認**
   - `dub build` / `dub test` によるコンパイル確認。
   - RenderQueue のユニットテストを追加し、Composite / DynamicComposite / Mask が期待通りの並びで Flush されることを検証する。
   - 既存の `render_queue.d` テストも新レイヤモデルに合わせて更新する。

---

## 期待される効果

- **Composite / DynamicComposite の親子関係が自動で保証される。**
  子ノードはターゲット設定後に確実に描画され、親はその結果テクスチャを使って最後に合成される。
- **同一ターゲット内での描画順序が zSort に基づき一貫性を持つ。**
  Stable ソートによりアーティストが定義した順序も失われない。
- **描画パスの可視化・デバッグが容易になる。**
  RenderPass と RenderItem をログ化することで、どのノードがどのターゲットへどう描画されたか追跡しやすい。
- **Backend 依存の処理をさらに抽象化できる。**
  ターゲットの push/pop やマスクコマンドの挿入は RenderQueue が一元管理できるため、新 Backend 追加時のコストが小さくなる。

以上の設計をもとに、次章の実装タスク（`doc/task.md`）を更新し、順次コードへ反映する。
