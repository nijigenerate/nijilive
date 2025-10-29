# 新レンダリングパイプライン 実装タスク

設計ドキュメント: `doc/new_rendering.md`

## ステップ1 TaskScheduler / DFS の整備
- [x] `Node.registerRenderTasks` で子ノードを **zSort 降順**に並び替えてから DFS する。
- [x] `Composite.selfSort()` / `DynamicComposite.selfSort()` / `Puppet.selfSort()` も降順に統一する。
- [x] タスク登録のデバッグログ（push/pop トークン、zSort）を一時的に挿入し、意図した順序で登録されているか確認する。

- [x] `RenderQueue` を RenderPass スタック構造に置き換え（Root / Composite / DynamicComposite）。
- [x] `RenderItem`（zSort + sequence + commands）と `RenderCommandBuffer` を導入し、`enqueueItem(zSort)` が常にスタックトップのパスへ追加されるようにする。
- [x] `pushComposite` / `popComposite` を実装。トークンでスコープを追跡し、`finalizeCompositePass` でコマンド列を組み立てる。
- [x] `pushDynamicComposite` / `popDynamicComposite` も同様に実装。
- [x] `flush()` が Root パスを zSort 降順で整列し、Backend へ平坦化したコマンド列を渡す。

## ステップ3 Node サイドの対応
- [x] Part の `runRenderTask` を `enqueueItem` ベースに書き換え（マスク＋描画を一括登録）。
- [x] Composite は `runRenderBeginTask` で `pushComposite(token)` を呼び、`runRenderEndTask` で `popComposite(token)`。
- [x] DynamicComposite も `pushDynamicComposite` / `popDynamicComposite` を使用する。
- [x] 子ノードの DFS と RenderQueue の zSort 両方で同じ順序（降順）が保たれることを確認する。

## ステップ4 Backend / マスク処理
- [x] OpenGL Backend の `BeginComposite` / `EndComposite` / `DrawCompositeQuad` を確認し、FBO 切り替えが旧実装通りになるよう調整。
- [x] ClipToLower / DodgeMask の Composite マスク処理を転送時にのみ適用する。
- [x] DynamicComposite の FBO 切り替え (`beginDynamicCompositeGL` / `endDynamicCompositeGL`) が RenderQueue のコマンド順に従うことを確認。

## ステップ5 テスト・ドキュメント
- [x] `source/nijilive/core/render/tests/render_queue.d` を更新し、以下を検証：
  - Part + マスク
  - Composite + 子 Part（マスク有無）
  - Composite ネスト（全スコープが順に畳まれるか）
  - DynamicComposite
- [x] `doc/rendering.md` を新パイプライン仕様へ更新。
- [ ] 不要となった旧ドキュメント／コメントの整理。

## ステップ6 検証・仕上げ
- [ ] `dub build` / `dub test` を実行し、既存テストが成功することを確認。
- [ ] 実際のモデル（ClipToLower 等を含む）で手動検証し、描画結果が期待通りであることを確認。
- [ ] デバッグログ／一時的な `writeln` 等を削除し、コードをクリーンアップする。
