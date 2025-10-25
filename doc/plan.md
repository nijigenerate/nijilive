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

3. **描画コマンドの細分化** *(進行中: Part を `DrawPartCommand` で RenderQueue に載せた段階。Composite/Mask 等の OpenGL 呼びを Backend コマンドに押し込む作業が残り。OpenGL 呼び出しを完全に Backend へ抽象化する必要がある。)*
   - Composite / Mask / MeshGroup / PathDeformer など、`drawOne()` 内で直接 OpenGL を呼んでいる箇所をコマンド化。
   - Stencil/FBO 切り替え、テクスチャ設定などを `RenderBackend` インターフェース経由で発行できるよう、`GPUCommand` バリエーションを追加する。

4. **旧パイプラインの削除**
   - `beginUpdate` / `update` / `endUpdate` の再帰呼び出しを完全に削除し、`run*Task` + RenderQueue の構成に一本化。
   - `drawOne()` 内の直接描画呼び出しを廃止し、すべてコマンド経由に置き換える。

5. **最終チェック / ドキュメント更新**
   - 主要ノード（Part, Composite, MeshGroup, Grid/PathDeformer, Mask など）の描画結果を確認。
   - `doc/rendering.md` を新パイプラインに差し替え、`doc/new_rendering.md` との整合性を取る。

## 備考
- 各ステップは段階的に PR/コミットを作成し、`rendering.md` の内容と実装の乖離が生じないよう随時更新する。
- OpenGL コマンド抽象化の際はテストしやすい Backend インターフェースを先に定義する。
