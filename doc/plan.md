# 新レンダリングパイプライン実装プラン

## ゴール
- `doc/new_rendering.md` に記載の TaskQueue + GPUQueue 方式へ完全移行し、`beginUpdate → update → endUpdate → draw` の再帰型パイプラインを廃止する。
- 各 Node が `run*Task` フック経由で処理を行い、描画は RenderQueue/GPUQueue に積んだコマンドのみで完結させる。

## ステップ
1. **RenderGraph / TaskScheduler の復活と整備** *(完了：全ノードが `registerRenderTasks` を通じて `run*Task` を登録し、`Puppet.update()` が `RenderGraph.buildFrame()`→`execute()` のみで処理する構造に移行済み。旧 `begin/update/end` 再帰呼び出しは空実装として除去。今後はステップ2以降へ進む。)*
   - `Puppet.update()` で `RenderGraph.buildFrame()` → `TaskScheduler.execute()` を呼ぶ構造に切り替える。
   - `Node.registerRenderTasks()` を全クラスで機能させ、DFS + zSort 順でタスクを積む。旧 `begin/update/end` 再帰呼び出しは順次削除。

2. **RenderContext / RenderQueue の導入** *(完了：RenderContext が RenderQueue/RenderBackend を保持し、`runRenderTask` から `DrawNodeCommand` を enqueue → `Puppet.draw()` で `renderQueue.flush(backend)` を実行する構造が整備済み。今後は各ノードの OpenGL 呼びをコマンド単位で分割するステップ3へ移行する。)*
   - `RenderContext` に `RenderQueue` 参照を渡し、`TaskOrder.Render` で `runRenderTask()` を実行する仕組みを実装。
   - 基本形として `DrawNodeCommand` を積み、`Puppet.draw()` では `RenderQueue.flush()` を呼ぶ。

3. **描画コマンドの細分化** *(進行中: Part の RenderQueue 化は途中段階。以下の順で実装する)*
   0. **バックエンド分離** … OpenGL 呼び出しは `nijilive.core.render.backends.*`（仮）に集約し、Node からは RenderBackend コマンドのみ発行する。
   1. **Part** … `drawOneImmediate` の OpenGL 呼びを backend へ移し、`DrawPartCommand` は描画データのみ保持。
   2. **Composite / Mask** … FBO 切替・マスク処理を Backend コマンド（例: `BeginComposite`, `EndComposite`）に分割し、子ノードの描画先を Backend 側で制御できるようにする。
   2a. **DynamicComposite** … 子ノードの描画先を一時的に内部 FBO へ差し替える仕組みを Backend コマンドとして表現し、描画終了後に差し替え前へ戻す（`BeginDynamicComposite`, `EndDynamicComposite`）。
   3. **MeshGroup / GridDeformer / PathDeformer** … 描画を担わない変形ノードとして整備（CPU 側で頂点変形を行い、描画は下流の Drawable コマンドに任せる）。
   4. **その他 Drawable** … `drawOne()` の OpenGL 呼び出しを backend へ移す。

4. **旧パイプラインの削除**
   - `beginUpdate` / `update` / `endUpdate` の再帰呼び出しを完全に削除し、`run*Task` + RenderQueue の構成に一本化。
   - `drawOne()` 内の直接描画呼び出しを廃止し、すべてコマンド経由に置き換える。

5. **最終チェック / ドキュメント更新**
   - 主要ノード（Part, Composite, MeshGroup, Grid/PathDeformer, Mask など）の描画結果を確認。
   - `doc/rendering.md` を新パイプラインに差し替え、`doc/new_rendering.md` との整合性を取る。

## 備考
- 各ステップは段階的に PR/コミットを作成し、`rendering.md` の内容と実装の乖離が生じないよう随時更新する。
- OpenGL コマンド抽象化の際はテストしやすい Backend インターフェースを先に定義する。
