# OpenGL タッチポイント一覧（Step 3.0-2）

`source/nijilive/core/nodes/**/*.d` で `bindbc.opengl` の関数を直接呼び出している箇所を分類し、Backend API で吸収すべき機能を整理する。

## Part (`source/nijilive/core/nodes/part/package.d`)
- 頂点/UV/変形バッファの更新: `glBindBuffer`, `glBufferData`（lines 196-198, 285-308）  
  → Backend API案: `uploadVertexBuffer(BufferHandle, Span!vec2, BufferUsage)`, `uploadUVBuffer`, `uploadDeformBuffer`.
- MRT 切り替え: `glDrawBuffers`（lines 218, 233, 252, 318）  
  → `setDrawBuffers(RenderTargets targets)`.
- シェーダ設定に伴う uniform 更新＋ブレンド設定: `inSetBlendMode` 内で `glBlendFunc`, `glBlendEquation`.  
  → `setBlendMode(BlendState state)`, `bindPartShader(PartShaderStage stage, PartUniforms uniforms)`.
- 頂点属性設定: `glEnableVertexAttribArray`, `glVertexAttribPointer`, `glDisableVertexAttribArray`（lines 285-309）  
  → `configureVertexArrays(VertexArrayDescriptor desc)`.
- テクスチャスロット管理: `glActiveTexture`, `glBindTexture`, `glBindFramebuffer` 等。  
  → `bindTextures(TextureSet set)`。
- マスク描画周り: `inBeginMask` 経由で stencil/state を直接操作。  
  → `beginMask(MaskState state)`, `drawMask(MaskPacket)`, `endMask()`.

## Composite (`source/nijilive/core/nodes/composite/package.d`)
- Composite quad 用 VAO/VBO の生成・設定: `glGenVertexArrays`, `glGenBuffers`, `glBindVertexArray`, `glBindBuffer`, `glBufferData`, `glEnableVertexAttribArray`, `glVertexAttribPointer`（lines 64-97）。  
  → `createFullscreenQuad()` もしくは `uploadQuadBuffer`.
- 描画時の MRT と VAO 操作: `glDrawBuffers`, `glBindVertexArray`, `glDrawArrays`（lines 162-188）。  
  → `drawCompositeQuad(CompositeDrawPacket packet)`.
- マスク時のステンシル操作: `glColorMask`, `glStencilOp`, `glStencilFunc`, `glStencilMask`, `glBlendFunc`（lines 240-266）。  
  → `configureStencil(StencilState state)`, `setColorMask(ColorMask mask)`.

## Mask (`source/nijilive/core/nodes/mask/package.d`)
- Part と同様に VBO/DBO/VAO 設定・描画 (`glEnableVertexAttribArray` 等) とステンシル操作 (`glColorMask`, `glStencilOp`, `glStencilFunc`, `glStencilMask`)。  
  → `drawMaskGeometry(MaskDrawPacket packet)`, `configureStencil`.

## Drawable 基底 (`source/nijilive/core/nodes/drawable.d`)
- 全 Drawable 共通の VBO/IBO/DBO 生成 (`glGenBuffers`), 更新 (`glBindBuffer` + `glBufferData`), 描画 (`glDrawElements`), VAO バインド。  
  → バッファ管理 API (`createBuffer`, `updateBuffer`, `bindVertexArray`), DrawCall API (`drawIndexed`).
- マスク処理ユーティリティ (`inBeginMask`, `inEndMask`) で `glEnable(GL_STENCIL_TEST)`, `glClearStencil`, `glClear`, `glStencilMask`, `glStencilFunc` 等。  
  → グローバルステート API (`setStencilTest`, `clearStencil`, `setStencilFunc`).

## その他（代表的なノード）
- `source/nijilive/core/nodes/composite/dcomposite.d`: `glDrawBuffers`, `glFlush`.  
  → `flushComposite()`.
- `source/nijilive/core/nodes/mask`, `grid.d`, `path.d` 自体は GL 依存少ないが、子 Drawable を走査する際にマスク API を再利用する必要あり。

## Backend API 設計サマリ
| カテゴリ | 代表的な関数 | Backend API案 |
| --- | --- | --- |
| バッファ管理 | `glBindBuffer`, `glBufferData`, `glGenBuffers` | `BufferHandle createBuffer(BufferDesc)`, `void uploadBuffer(BufferHandle, const(void)[] data, BufferUsage)` |
| 頂点属性/VAO | `glEnableVertexAttribArray`, `glVertexAttribPointer`, `glBindVertexArray` | `void configureVertexLayout(VertexLayout layout)`, `void bindVertexArray(VertexArrayHandle)` |
| MRT/FBO | `glDrawBuffers`, `glBindFramebuffer` | `void setRenderTargets(RenderTargets targets)`, `void bindFramebuffer(FrameBufferHandle handle)` |
| ブレンド/カラー/ステンシル | `glBlendFunc`, `glBlendEquation`, `glColorMask`, `glStencil*` | `void setBlendState(BlendState)`, `void setColorMask(ColorMask)`, `void setStencilState(StencilState)` |
| テクスチャ | `glActiveTexture`, `glBindTexture` | `void bindTextureSet(TextureBinding[])` |
| ドローコール | `glDrawElements`, `glDrawArrays` | `void drawIndexed(DrawPacket)`, `void drawArrays(DrawPacket)` |
| マスク | `inBeginMask` 系で複数ステンシル操作 | `BeginMask`, `ApplyMask`, `EndMask` コマンド |
| Composite 専用 | `glDrawBuffers`, `glFlush`, quad draw | `BeginComposite`, `CompositeDrawQuad`, `EndComposite` |

この一覧を元に、RenderBackend インターフェースへ段階的に API を追加し、Node 側の `bindbc.opengl` 依存を剥離していく。
