# 新レンダリングパイプライン実装タスク

## ステップ1 RenderGraph / TaskScheduler
- [x] `source/nijilive/core/puppet.d` の `Puppet.update()` を `RenderGraph.buildFrame()` → `RenderGraph.execute()` 呼びのみで構成する。
- [x] `source/nijilive/core/nodes/package.d` で全ノードが `registerRenderTasks()` を通じて `TaskScheduler` に登録し、旧 `begin/update/end` 再帰を空実装化する。

## ステップ2 RenderContext / RenderQueue
- [x] `source/nijilive/core/render/queue.d` を導入し、`RenderContext.renderQueue` に積んだ `RenderCommand` のみで描画する。
- [x] `Puppet.draw()` 相当処理で `renderQueue.flush(renderBackend)` を呼び、RenderQueue/Backend 経由に一本化する。

## ステップ3 描画コマンドの細分化（実施中）
### 3.0 バックエンド分離
- [x] `RenderQueue` が保持する `RenderCommand` に Backend コマンド ID とパラメータ構造体を持たせ、Node 側は API 呼び出しデータの生成に限定する。
- [x] `source/nijilive/core/render/backends/package.d`（新規）で `RenderBackend` の機能一覧を定義し、OpenGL 実装（`GLRenderBackend`）を `backends/opengl` 配下に隔離する。
- [x] `source/nijilive/core/nodes/**/*.d` で `bindbc.opengl` へ直接触れている箇所を列挙し、対応する Backend API (例: `setBlendMode`, `bindFrameBuffer`, `drawBuffers`) を設計する。
- [x] `RenderContext` へ GPU ステートキャッシュ（現在の FBO、DrawBuffers 等）を追加し、Backend 実装が参照できるようにする。

### 3.1 Part OpenGL 分離
- [x] `source/nijilive/core/render/commands.d` に `PartDrawPacket` を追加し、行列・色・ブレンド状態など描画に必要な CPU 側データをまとめて RenderQueue に積む構成へ切り替える。
- [x] `Part.drawSelf()` で必要な定数バッファ・ユニフォーム・テクスチャ参照および VBO/IBO ハンドルを `PartDrawPacket` に詰める実装を行う。
- [x] `source/nijilive/core/render/backends/opengl/part.d` に `executePartPacket(const PartDrawPacket packet)` を実装し、これまで `Part.drawSelf()` が直接呼んでいた `gl*` 群を移植する。
- [x] `source/nijilive/core/nodes/part/package.d` の `drawSelf` / `setupShaderStage` / `renderStage` から OpenGL 呼び出しを削除し、代わりに `ctx.renderQueue.enqueue(makeDrawPartCommand(packet))` を行う。
- [x] Part のマスク処理 (`inBeginMask` 等) を Backend コマンド（`BeginMask`, `ApplyMask`, `EndMask`）に変換し、`glDrawPart()` ではなく RenderQueue 経由でマスクを組み立てる。
- [ ] `test` 配下に Part 専用の描画検証テスト（例: `test/render/part_backend.d`）を追加し、`DrawPartCommand` 実行結果が旧パスと一致するか確認する。

### 3.2 Composite / Mask
- [ ] `source/nijilive/core/nodes/composite/package.d` の `drawContents()` / `drawSelfImmediate()` での `inBeginComposite` / `glDrawBuffers` 呼びを Backend コマンド（`BeginComposite`, `EndComposite`, `CompositeDrawQuad`）へ移す。
- [ ] Composite のマスク (`Composite.renderMaskImmediate`) を `DrawCompositeMaskCommand` でデータ化し、Backend 側で子 Part を順序制御できるようにする。
- [ ] `source/nijilive/core/nodes/mask/package.d` のマスク生成処理を `MaskDrawPacket` に分離し、Part との共有ロジックを Backend にまとめる。

### 3.2a DynamicComposite
- [ ] `source/nijilive/core/nodes/composite/dynamic.d`(※存在箇所) での一時 FBO 差し替えロジックを `BeginDynamicComposite`/`EndDynamicComposite` コマンドに置き換える。
- [ ] Backend に RenderTarget スタックを実装し、DynamicComposite 子描画中の FBO/テクスチャを自動で push/pop する。

### 3.3 MeshGroup / GridDeformer / PathDeformer
- [ ] `source/nijilive/core/nodes/meshgroup/package.d` の `drawOne()` を廃止し、`runDynamicTask` で頂点更新を行った後、対象 Drawable の `PartDrawPacket` へデータを渡す。
- [ ] `source/nijilive/core/nodes/deformer/grid.d` / `path.d` の `drawOne()` を空実装へ変更し、変形処理は CPU 側バッファ更新コマンド (`UpdateVertexBufferCommand`) として RenderQueue に積む。
- [ ] メッシュ変形で必要な GPU バッファの更新を Backend API で表現し、OpenGL 直接呼び (`glBindBuffer/glBufferData`) を禁止する。

### 3.4 その他 Drawable
- [ ] `source/nijilive/core/nodes/**/*.d` で `gl*` を直接呼ぶ Drawable を洗い出し、Part と同様の DrawPacket + Backend 実行モデルへ統一する。
- [ ] BlendShader など特殊処理が必要な Drawable について、Backend に専用コマンド（例: `ExecuteBlendShaderCommand`）を設け、Node 側は状態記述のみ持つようにする。
- [ ] OpenGL 依存のユーティリティ (`inDrawTextureAtPart`, `inDrawTextureAtPosition` など) を `source/nijilive/core/render/backends/opengl/**` 配下へ移設し、ノード側から OpenGL 参照を完全排除する。

## ステップ4 旧パイプライン削除
- [ ] `source/nijilive/core/nodes/package.d` から `beginUpdate` / `update` / `endUpdate` の残骸を削除し、関連呼び出しを含むテストを更新する。
- [ ] Drawable の `drawOne()` / `drawOneImmediate()` をすべて削除 or 非公開化し、RenderQueue 経由以外の描画ルートが存在しないことを確認する。

## ステップ5 最終チェック / ドキュメント更新
- [ ] Part / Composite / MeshGroup / GridDeformer / PathDeformer / Mask の代表モデルを用意し、新旧パイプラインの描画結果を比較するための自動テスト or キャプチャスクリプトを実装する。
- [ ] `doc/rendering.md` を新パイプライン仕様に全面改訂し、`doc/new_rendering.md` の説明と差異がないかクロスチェックする。
- [ ] RenderBackend/API の利用方法を `doc/new_rendering.md` 末尾に追記し、今後追加されるノードが従うべき実装ガイドラインを整備する。
