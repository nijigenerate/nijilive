# 新レンダリングパイプライン再設計案（TaskQueue / RenderQueue / GPUQueue）

本ドキュメントは 2025-03 時点の課題を踏まえ、TaskScheduler（TaskQueue[N]）と
RenderQueue / GPUQueue を再設計するための方針を整理する。Composite のターゲット
切り替えや zSort・マスクの整合性を維持しつつ、既存のパイプライン構造を明確化する。

---

## 1. 既存パイプラインの分解

### 1-1. TaskScheduler と TaskQueue[N]

- `TaskScheduler` は固定順の `TaskOrder` を持ち、それぞれ `TaskQueue[TaskOrder]` に
  `runBeginTask` / `runRenderTask` / `runRenderEndTask` 等のデリゲートを登録する。
- `Puppet.update()` はルートノードから DFS しながら Task を登録。登録時に子ノードを
  **zSort 降順**（大きい値ほど手前）に並べ替える。
- `TaskScheduler.execute(ctx)` が `TaskOrder.Init` → `TaskOrder.Parameters` → `...` →
  `TaskOrder.RenderEnd` まで順番に TaskQueue[N] を処理する。`Parameters` フェーズでは
  パラメータ更新とそれに伴う deformStack の再評価が行われ、続く `PreProcess` 以降で
  各ノードが最新状態を前提に処理できる。

### 1-2. GPUQueue（旧 RenderQueue）

- TaskQueue の各フェーズでノードが `RenderQueue`（旧称 GPUQueue）へ GPU コマンドを
  積む。`RenderQueue.flush()` が Backend（OpenGL 実装）にコマンドを渡して描画を実行。
- 課題：Composite の子描画が親ターゲットに直接流れる／zSort が維持されない／マスクの
  適用タイミングが崩れる。

---

## 2. 再設計のゴール

1. **Composite / DynamicComposite の子ノードが専用 FBO に描かれ、その結果だけを
   親ターゲットへブリット** する。ターゲット切替は RenderQueue が集中管理する。
2. **同じターゲット（Root / Composite / DynamicComposite）を共有するノードは、
   TaskQueue での親→子順を維持したまま RenderQueue 内で zSort 降順に再整列** される。
   これにより DFS の構造を壊さず、同一ターゲット内で「奥→手前」の描画順が保証される。
3. **マスク（ClipToLower 等）は転送時のみ適用** され、子描画時には混ざらない。
4. **スコープ（push/pop）が必ず対応** し、ネスト時に崩壊しない。

---

## 3. RenderQueue の再設計

### 3-1. RenderPass と RenderItem

- RenderQueue は `RenderPass` をスタックで管理。パス種別は `Root / Composite / DynamicComposite`。
- 各パスは `RenderItem[]` を持ち、RenderItem は `(float zSort, size_t sequence, RenderCommandData[] cmds)` を保持。
- `enqueueItem(zSort, builder)` で「現在のスタックトップの RenderPass」に RenderItem を追加する。
  Composite/DynamicComposite が `push*` を呼んでいる間はそのパスがトップに居続けるため、
  子 Part はヒント無しで適切なターゲットへ enqueue される。

### 3-2. スコープ API

```d
size_t pushComposite(Composite comp, bool useStencil, MaskApplyPacket[] packets);
void   popComposite(size_t token, Composite comp);
size_t pushDynamicComposite(DynamicComposite comp);
void   popDynamicComposite(size_t token, DynamicComposite comp);
```

- `push*` は新しい RenderPass を生成しスタックに積む。戻り値のトークンで対応関係を管理。
- `pop*` はスタック上を上から調べ、目的トークンに到達するまで `finalizeTopPass(true)` で
  内側スコープを順に畳む。目的トークンを見つけたら `finalizeCompositePass(false)` を実行。

### 3-3. finalizeCompositePass

1. パス内の RenderItem を **zSort 降順 + sequence 安定**で整列。
2. `BeginComposite → 子 RenderItem を展開 → EndComposite` を親パスへ追加。
3. マスクがあれば `BeginMask → ApplyMask* → BeginMaskContent → DrawCompositeQuad → EndMask` を挿入。
4. Composite 側に「閉じた」ことを通知（フラグ／トークンをリセット）。
   ネストした Composite の場合でも、RenderQueue が親スコープを再開できるよう
   OpenGL 側では FBO のスタックを管理する。

DynamicComposite の `finalizeDynamicCompositePass` も同様に `BeginDynamicComposite → 子 → EndDynamicComposite` を構築し、親パスへ追加する。

### 3-4. flush

- Root パスの RenderItem を zSort 降順＋登録順で整列し、平坦化したコマンド列を Backend に渡す。
- Backend は `RenderCommandKind` ごとに FBO 切替・マスク・描画を行う。
- CommandKind 例：`BeginComposite` / `EndComposite` / `DrawPart` / `DrawCompositeQuad` / `BeginMask` / `EndMask` 等。

---

## 4. ノード側の修正

| ノード             | runRenderBeginTask                     | runRenderTask                               | runRenderEndTask                         |
|--------------------|----------------------------------------|---------------------------------------------|------------------------------------------|
| Part               | なし                                   | `enqueueItem(zSort)` でマスク＋描画まとめ | なし                                     |
| Composite          | `pushComposite(token)`                 | 子ノードのみ                                | `popComposite(token)`                    |
| DynamicComposite   | `pushDynamicComposite(token)`          | 子ノードのみ                                | `popDynamicComposite(token)`             |

- 子ノード配列 (`children` や `subParts`) は `selfSort()` で **zSort 降順**に整列してから登録・描画を行う。
- Part は自分の RenderItem 内でマスクコマンドを完結させる。

---

## 5. TaskQueue / RenderQueue / GPUQueue の連携

1. **TaskQueue (TaskOrder)**
   - `runRenderBeginTask` で `pushComposite` / `pushDynamicComposite` を呼ぶ。
   - `runRenderTask` で Part が `enqueueItem` を追加。Composite は子に処理を委譲。
   - `runRenderEndTask` で `popComposite` / `popDynamicComposite` を呼び、RenderQueue にまとめて描画命令を登録。
2. **RenderQueue**
   - RenderPass スタックを維持。各パスの RenderItem を zSort 降順で整列し、親パスに吸い上げる。
3. **GPUQueue（Backend 実行）**
   - `flush()` で Root パスのコマンド列を生成し、Backend（OpenGL）が実際に FBO 切替・マスク・描画を行う。


~~~mermaid
flowchart TD
    A[Puppet.update / TaskQueue] --> B[RenderQueue push/pop]
    B --> C[RenderQueue 総合並び替え]
    C --> D[GPUQueue / Backend 実行]
~~~

---

## 6. モジュールごとの対応内容

### 6-1. TaskScheduler (`source/nijilive/core/render/scheduler.d`)
- 子ノード登録時に zSort 降順で並べ替える。
- TaskQueue の実行順は従来どおりだが、Composite の `runRenderBeginTask` / `runRenderEndTask` が
  push/pop を呼ぶことを前提にデバッグログを整備する。

### 6-2. RenderQueue (`source/nijilive/core/render/queue.d`)
- 現状の FIFO 実装を廃し、RenderPass スタック＋安定ソート構造に置き換える。
- `pushComposite` / `popComposite` ではトークン付きスコープ管理と zSort 整列を実行。
- `finalizeTopPass(true)` でトークン未一致時でも安全に自動クローズできるようにする。

### 6-3. Node 実装
- Part (`source/nijilive/core/nodes/part/package.d`) は `enqueueItem` を通じてマスク＋描画を登録。
- Composite (`source/nijilive/core/nodes/composite/package.d`) は `pushComposite`/`popComposite` の呼び出しと子 `subParts` の zSort 降順整列を徹底。
- DynamicComposite (`source/nijilive/core/nodes/composite/dcomposite.d`) は `pushDynamicComposite`/`popDynamicComposite` に置き換える。

### 6-4. Backend（OpenGL 実装）
- `BeginComposite` / `EndComposite` が FBO 切替（`glBindFramebuffer(cfBuffer)` / `fBuffer`）を行う。
- `DrawCompositeQuad` が Composite の結果を親ターゲットに転送。ClipToLower 等はここで適用される。

---

## 7. テスト計画

1. **ユニットテスト更新**
   - Part 単独 / マスク付き Part。
   - Composite + 子 Part（マスクなし）→ コマンド列が `BeginComposite → DrawPart → EndComposite → DrawCompositeQuad` になるか確認。
   - Composite + ClipToLower（マスク付き）→ 転送時にのみ `BeginMask` が挿入されるか確認。
   - Composite ネスト（意図的に pop 順序を崩して finalizeTopPass が働くケース）。
   - DynamicComposite。

2. **手動検証**
   - 高 zSort（フォアグラウンド）→ 低 zSort（バックグラウンド）の重なり確認。
   - ClipToLower のマスク領域が Composite 結果にのみ適用されるか確認。

3. **自動テスト/CI**
   - `dub test` に RenderQueue のコマンド列比較を追加し、期待シーケンスと一致するか検証。
   - GPU パスを含む integration テストが整備できれば、RenderQueue の平坦化結果をスナップショット化する。

---

## 8. 今後の課題

- RenderQueue のログ出力（debug ビルド時）を強化し、Composite の push/pop 対応や自動クローズを視覚化する。
- ClipToLower 等を含むサンプルシーンを作成し、回帰テストの一部に組み込む。
- 他 Backend（Vulkan など）を追加する際にも同じ RenderQueue 構造を再利用できるよう、コマンド列と Backend 実装の責務を明確に分離する。

---

以上が TaskQueue[N] と RenderQueue/GPUQueue の連携を再構築し、Composite のターゲット切り替え・zSort・マスクを確実に制御するための再設計案である。実装フェーズではこの設計を基にコードを更新し、ユニットテストと手動検証で挙動を確認する。
