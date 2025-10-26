# 新レンダリングパイプライン実装タスク

## ステップ1: RenderGraph / TaskScheduler
- [x] `Puppet.update()` の処理を `RenderGraph.buildFrame()` → `TaskScheduler.execute()` のみで完結させる。
- [x] 全 Node で `registerRenderTasks()` を実装し、DFS+ZSort でタスクを積む旧 `begin/update/end` 再帰を除去する。

## ステップ2: RenderContext / RenderQueue
- [x] `RenderContext` が `RenderQueue`/`RenderBackend` を保持し、`TaskOrder.Render` の `runRenderTask()` からコマンドを enqueue する。
- [x] `Puppet.draw()` が `RenderQueue.flush(backend)` を呼び出し、描画がキュー駆動のみになる。

## ステップ3: 描画コマンドの細分化（進行中）
### 3.0 バックエンド分離
- [ ] `nijilive.core.render.backends.*` に RenderBackend インターフェースと OpenGL 実装（GLBackend 仮）を定義する。
- [ ] 既存ノードが直接呼んでいる OpenGL 関数を列挙し、RenderBackend API へ写経する（状態セット、リソースバインド、描画命令など）。
- [ ] RenderQueue が RenderBackend コマンドに依存し、Node 側は API 呼びを発行するだけに切り替える。

### 3.1 Part の RenderQueue 化
- [ ] `DrawPartCommand` に Part 描画に必要なデータパケット（頂点/UV/色/テクスチャ参照、Blend モードなど）だけを保持させる。
- [ ] `Part.drawOneImmediate()` で行っている OpenGL 呼び出しを RenderBackend 実装へ移し、`DrawPartCommand::execute()` から Backend 呼びを行う。
- [ ] Part ノードの Task 登録が DrawQueue ベースで完了するかを `test/part_rendering.d`（仮）などで確認し、旧コードを削除する。

### 3.2 Composite / Mask
- [ ] FBO やマスク操作を Backend コマンド (`BeginComposite`/`EndComposite` 等) に落とし込み、Node は子タスク登録のみ行う。
- [ ] Composite ノード内での `glBindFramebuffer` 系呼び出しを完全に禁止し、Backend 側で accumulate する。
- [ ] Mask ノードについてもテクスチャ / 深度ステンシル状態遷移を Backend 管理に移す。

### 3.2a DynamicComposite
- [ ] 子ノード描画先差し替えを `BeginDynamicComposite`/`EndDynamicComposite` コマンドで表現し、RenderQueue 側で一時 FBO を割り当てる。
- [ ] 差し替え前後の RenderTarget/Sampler 状態を Backend がスタック管理する仕組みを実装する。

### 3.3 MeshGroup / GridDeformer / PathDeformer
- [ ] 変形ノードを CPU 処理専用タスクに再整理し、描画命令を下流 Drawable へ明示的に引き渡す。
- [ ] `drawOne()` 内の OpenGL 呼び出しをすべて削除し、RenderQueue へ頂点バッファ更新 or 参照を行う形に改修する。

### 3.4 その他 Drawable
- [ ] Part 以外の Drawable（例: Live2D Mesh、Sprites など）の `drawOne()` を RenderBackend コマンドへ移行する。
- [ ] 直接 OpenGL を叩く既存コードをリストアップし、RenderQueue/Backend 経由に統一する。

## ステップ4: 旧パイプライン完全削除
- [ ] `beginUpdate` / `update` / `endUpdate` の空実装を含め完全に削除する。
- [ ] `drawOne()` から直接描画するパスを排除し、RenderQueue 経由のみが利用されているか確認する。

## ステップ5: 最終チェック / ドキュメント更新
- [ ] Part / Composite / MeshGroup / GridDeformer / PathDeformer / Mask の描画結果を比較検証する。
- [ ] `doc/rendering.md` を新パイプライン仕様に更新し、`doc/new_rendering.md` との差分を解消する。
- [ ] RenderBackend/API の利用方法をドキュメント化し、今後のノード実装ガイドラインを追加する。
