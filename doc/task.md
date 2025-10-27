# 新レンダリングパイプライン実装タスク（Layered RenderQueue 対応）

## ステップ1 RenderQueue のレイヤ化
- [x] `RenderQueue` に `RenderPass` / `RenderItem` / `RenderCommandBuffer` を導入し、root パスの初期化を行う。
- [x] `enqueueItem(zSort, builder)`・`pushComposite`・`pushDynamicComposite`・`popComposite`・`popDynamicComposite` といった新 API を実装する。
- [x] `flush()` で各パスの RenderItem を zSort 降順（安定ソート）で整列し、子パスを親パスへ展開する処理を実装する。
- [x] 既存の `enqueue(RenderCommandData)` は互換のために残すか、新 API への移行を強制する形で削除する。

## ステップ2 ノード側の対応
- [x] `Node.runRenderTask`（フォールバック）を新しい `enqueueItem` を用いる実装に置き換える。
- [x] `Part.enqueueRenderCommands` を `enqueueItem` ベースへ書き換え、マスクを含むコマンド列を一つの RenderItem として生成する。
- [x] `Composite.runRenderBeginTask` / `runRenderEndTask` を `pushComposite` / `popComposite` に置き換え、子 RenderItem をまとめたコマンド列を親パスへ登録する。
- [x] `DynamicComposite` で `pushDynamicComposite` / `popDynamicComposite` を利用し、子描画と合成を 1 アイテムにまとめる。

## ステップ3 付随モジュール更新
- [x] `RenderCommandKind` / `RenderCommandData` が新 API で扱いやすい形になっているか確認し、必要であれば補助関数を追加する。
- [x] `RenderContext`・`Puppet.update` 周りで `renderQueue.beginFrame()`（または `clear()`）を適切なタイミングで呼ぶよう調整する。

## ステップ4 テスト・ドキュメント
- [x] `source/nijilive/core/render/tests/render_queue.d` を新レイヤモデルに合わせて更新し、Composite / DynamicComposite / Part の描画順序が期待通りであることを検証する。
- [ ] 必要に応じて追加のユニットテスト（例: マスク付き Part + Composite の組み合わせ）を作成する。
- [ ] `doc/rendering.md` を `doc/new_rendering.md` の内容に合わせて追記・更新する。
- [ ] `doc/new_rendering.md` の方針とコード実装の差分を最終確認し、コメント・ログ出力の整合性を取る。
