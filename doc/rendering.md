# 新レンダリングパイプライン（TaskScheduler → RenderQueue）

nijilive は `TaskScheduler` と `RenderQueue` を核としたパイプラインへ移行済みである。各ノードは

1. 親→子の DFS を 1 回だけ行って Task を登録し、
2. Task を順番に実行して CPU 側処理を完了し、
3. 描画は RenderQueue に積んだコマンドを Backend が解釈する

という 3 段構成で動作する。本ドキュメントでは現行仕様を整理する。従来の再帰パイプラインは `doc/old_rendering.md` を参照。

```mermaid
flowchart TD
    A[Puppet.update] --> B[actualRoot.registerRenderTasks<br/>(親→子 1pass)]
    B --> C[TaskScheduler.execute<br/>TaskOrder 1..N]
    C --> D[RenderQueue.enqueue<br/>GPUCommand Only]
    D --> E[Puppet.draw<br/>RenderQueue.flush(Backend)]
```

## フレーム処理

1. **`Puppet.update()`**
   - Transform／Driver 更新など従来の CPU 処理を行い、`RenderContext` を初期化する
     (`renderQueue` をクリアし、`renderBackend` と `RenderGpuState` を設定)。
   - `actualRoot.registerRenderTasks(taskScheduler)` が親→子の DFS を 1 回だけ走らせ、
     各ノードの `registerRenderTasks` が Task を `TaskScheduler` へ登録する。
   - `taskScheduler.execute(ctx)` が TaskOrder 1..N の順で handler を実行する。
     Node 側は `runBeginTask` / `runDynamicTask` / `runRenderTask` などのフックを通じて
    CPU 処理を終え、描画が必要な場合のみ `ctx.renderQueue.enqueueItem(...)` あるいは
    `pushComposite` / `pushDynamicComposite` を通じて RenderQueue へ登録する。

2. **`Puppet.draw()`**
   - `renderQueue` が空でなければ `renderQueue.flush(renderBackend, renderContext.gpuState)` を呼び、
     すべての描画コマンドを Backend で実行する。
   - 何らかの理由で Queue が空（旧ルートや互換パス）であった場合のみ、
     `rootParts.drawOne()` を後方互換として呼び出す。

## TaskScheduler と Node フック

`TaskScheduler` は固定の `TaskOrder` を持つ。Node は `registerRenderTasks` で親ノードの Task を先に登録し、子ノードを再帰的に登録、最後に `RenderEnd` を差し込む。これにより **RenderBegin → (子ども) → RenderEnd** の順序が保証される。

| TaskOrder        | 呼び出されるメソッド                    | 代表的な処理例                                             |
|------------------|----------------------------------------|------------------------------------------------------------|
| `Init`           | `runBeginTask()`                       | オフセット・フラグ初期化、変形キャッシュのリセット         |
| `PreProcess`     | `runPreProcessTask()`                  | `translateChildren`、デフォーマ設定                       |
| `Dynamic`        | `runDynamicTask()`                     | ドライバ／フィジックス更新、DynamicComposite の更新など    |
| `Post0..2`       | `runPostTask(id)`                      | `postProcess` 各ステージ                                   |
| `RenderBegin`    | `runRenderBeginTask(RenderContext)`    | Composite / Mask の Begin コマンド発行                    |
| `Render`         | `runRenderTask(RenderContext)`         | Part 等が Draw コマンドを RenderQueue に積む               |
| `RenderEnd`      | `runRenderEndTask(RenderContext)`      | Composite の End、Mask の片付け                            |
| `Final`          | `runFinalTask()`                       | 通知フラッシュなど                                         |

親ノードの RenderBegin が子ノードより先に、RenderEnd が子ノードより後に登録されるため、
Composite の FBO 切り替えや Mask スタックの整合性が保たれる。

## RenderQueue と GPUQueue

`RenderQueue` は RenderPass（Root / Composite / DynamicComposite）をスタック管理し、
各パス内に `RenderItem`（`zSort`・追加順・コマンド列）を保持する。ノードは
`enqueueItem(zSort, builder)` で現在のパスにコマンドを追加し、Composite / DynamicComposite は
`push*` / `pop*` を用いて専用スコープを開閉する。

- Root: ルートターゲット (fBuffer)。Part や最終 `DrawCompositeQuad` がここに積まれる。
- Composite: `BeginComposite → 子 Part → EndComposite` を組み立て、必要なら
  `BeginMask → ApplyMask* → BeginMaskContent → DrawCompositeQuad → EndMask` を挿入して親へ返す。
- DynamicComposite: `BeginDynamicComposite → 子 Part → EndDynamicComposite` を構築し、その後
  DynamicComposite 自身が Part と同じ `DrawPart` を発行する。

各パスの RenderItem は **zSort 降順（手前→奥）＋追加順**で安定ソートされてから親パスへ展開される。
`flush()` は Root パスを同様に整列し、平坦化したコマンド列（GPUQueue）を Backend へ渡す。

`nijilive.core.render.commands` に定義される主な `RenderCommandKind` と Backend の役割は以下の通り。

| コマンド                                         | 主な発行元                         | Backend の役割                            |
|--------------------------------------------------|------------------------------------|-------------------------------------------|
| `BeginMask` / `ApplyMask` / `BeginMaskContent` / `EndMask` | Part / Composite                 | ステンシル設定とマスク適用                |
| `DrawPart`                                       | Part / DynamicComposite            | VBO/IBO/テクスチャをバインドして描画      |
| `BeginComposite` / `EndComposite`                | Composite                          | Composite 用 FBO の切り替え               |
| `DrawCompositeQuad`                              | Composite                          | Composite 結果を親ターゲットへ転送        |
| `BeginDynamicComposite` / `EndDynamicComposite`  | DynamicComposite                   | 動的ターゲット用 FBO の切り替え           |
| `DrawMask`                                       | Mask                               | マスクジオメトリ描画                      |
| `DrawNode`                                       | 互換パス                           | 旧 `node.drawOne()` 呼び出し               |

## OpenGL Backend の責務

OpenGL 実装 (`nijilive.core.render.backends.opengl.*`) は、

- `part_resources.d` / `mask_resources.d` / `drawable_buffers.d` などで GPU バッファやシェーダを初期化し、
- `part.d` / `mask.d` / `composite.d` などで RenderQueue のコマンドを実際の `gl*` 呼び出しに変換する。

Node 側から直接 OpenGL を呼ぶコードは撤去され、RenderBackend 経由でのみアクセスする。
ユニットテストでは `version(unittest)` のスタブを用意し、GL コンテキスト無しでテストが実行できる。

## 代表ノードの振る舞い

- **Part**  
  `runRenderTask` で `PartDrawPacket` を生成し、必要なら Mask コマンドを前後に挟む。
  `renderMask` / `drawSelf` などの互換 API も内部で RenderQueue を新規作成し Backend を呼ぶ。

- **Composite**  
  `runRenderBeginTask` で `BeginMask`（必要な場合）→`BeginComposite` を積み、
  `runRenderEndTask` で `DrawCompositeQuad` → `EndComposite` → `EndMask` を積む。
  子 Part は同じ RenderQueue 上で描画されるため、FBO 切り替えが自動的に作用する。

- **DynamicComposite**  
  `BeginDynamicComposite` / `EndDynamicComposite` で RenderTarget スタックを制御し、
  Composite の仕組みを拡張して動的な合成先を扱う。

- **MeshGroup / GridDeformer / PathDeformer**  
  `runRenderTask` を空実装とし、CPU 側で頂点変形のみを行う。GPU コマンドは一切発行しない。

## 旧パイプラインとの関係

- 旧 `drawOne()` 系 API は可能な限り RenderQueue を経由する形に書き換えてあるが、
  互換目的で残っているコードパスも存在する。必要に応じて `doc/old_rendering.md` を参照して挙動を比較すること。
- `RenderQueue` が空だった場合に限り、`Puppet.draw()` が旧 `rootPart.drawOne()` を呼ぶ。
  移行漏れが無いか確認する際は RenderQueue の中身とこのフォールバックを併せて点検する。

## 今後のメンテナンス指針

1. 新しい Drawable／Deformer を追加するときは、
   - `runRenderTask`（あるいは RenderBegin/End）で RenderQueue にコマンドを積むだけに留め、
   - OpenGL 固有処理は `nijilive.core.render.backends` 配下の Backend 実装へ追加する。

2. Backend を追加したい場合は `RenderBackend` インタフェースを実装し、`RenderCommandKind` のハンドリングを行う。
   OpenGL 実装を参考に、モジュール分割（シェーダ初期化／バッファ管理／コマンド実行）を揃えると移植しやすい。

3. 旧パイプラインに依存したドキュメントやテストを修正する場合は、
   既存の Snapshot テスト（`source/nijilive/core/render/tests/render_queue.d`）を活用し、
   RenderQueue に積まれるコマンド列を基準に検証する。

以上が現行レンダリングパイプラインの仕様である。これを前提に Step5（仕様ドキュメント整備・自動テストの追加）を進めること。
