# Rendering Command Stream Plan

## Objective
Replace the RenderCommandData/RenderCommandBuffer pipeline with a backend-dependent command emitter. GraphBuilderと各ノードは emitter を通してノード参照を直接渡し、OpenGL など backend 実装がパケット生成と GPU 呼び出しを担う。これによりデータコピーを減らし、将来の backend 追加を容易にする。

## Plan
1. **Emitter インターフェース設計**
   - `RenderCommandEmitter` を定義し、Part/Mask/Composite/DynamicComposite の描画・スコープ操作メソッドを列挙する。
   - 引数は可能な限り `Part` 等のノード参照＋必要なフラグに限定し、状態は backend 側で取得。
2. **GraphBuilder 書き換え**
   - GraphBuilder に emitter インスタンスを渡し、`RenderCommandBuffer`/`RenderCommandData` を廃止。
   - z-sort された RenderPass を emitter 呼び出し列として再生する仕組みを実装する。
3. **ノード側の更新**
   - `Part.enqueueRenderCommands` や `Composite`/`DynamicComposite` などが emitter を利用するように書き換え、パケット生成を backend へ移譲。
   - DynamicComposite の postCommands delegate も emitter 呼び出しへ置き換える。
4. **キャッシュ/テスト戦略**
   - Puppet の `cachedCommands` を一時的に廃止し、常に GraphBuilder → emitter として実行。
   - ユニットテスト用に RecordingEmitter を作成し、既存の挙動検証を置き換える。
5. **OpenGL 実装**
   - 旧 RenderQueue をベースに `RenderCommandEmitter` の OpenGL 実装を追加し、パケット生成と flush を内部で完結させる。
   - Puppet/runtime_state から OpenGL emitter を生成し、既存の flush 経路を更新。
6. **ドキュメントとフォローアップ**
   - `doc/rendering.md` や関連資料を emitter ベースのフローに更新。
   - 将来の DirectX/Vulkan backend を emitter 実装として追加できるよう、公開 API を整理。

依存タスクや進捗は `doc/task.md` で管理する。
