# ⚠ このドキュメントは生成AIを用いて自動的に生成されたものです。現在、正確さをレビュー中です ⚠

# Nijilive INPバイナリ・JSONシリアライズ出力フォーマット構造説明

本書は、Nijiliveが生成・読み込みを行うINPバイナリファイルの全体構造および、その中に格納されるJSONシリアライズ出力データのフォーマット構造について、各セクションやフィールドの役割および文法を形式的に定義するための資料です。

---

## 目次

- [⚠ このドキュメントは生成AIを用いて自動的に生成されたものです。現在、正確さをレビュー中です ⚠](#-このドキュメントは生成aiを用いて自動的に生成されたものです現在正確さをレビュー中です-)
- [Nijilive INPバイナリ・JSONシリアライズ出力フォーマット構造説明](#nijilive-inpバイナリjsonシリアライズ出力フォーマット構造説明)
  - [目次](#目次)
- [1. INPバイナリフォーマット全体構造（実装仕様）](#1-inpバイナリフォーマット全体構造実装仕様)
  - [1.1 ファイル全体レイアウト](#11-ファイル全体レイアウト)
  - [1.2 セクション識別子と構造](#12-セクション識別子と構造)
  - [1.3 JSONセクション](#13-jsonセクション)
  - [1.4 テクスチャセクション（"TEX\_SECT"）](#14-テクスチャセクションtex_sect)
  - [1.5 拡張セクション（"EXT\_SECT"）](#15-拡張セクションext_sect)
  - [1.6 バージョン管理・拡張性](#16-バージョン管理拡張性)
  - [1.7 仕様駆動の「チャンクヘッダ」形式との比較](#17-仕様駆動のチャンクヘッダ形式との比較)
  - [2. トップレベル構造](#2-トップレベル構造)
    - [2.1 Puppet構造（JSONルート）](#21-puppet構造jsonルート)
    - [2.2 Meta セクション](#22-meta-セクション)
    - [2.2 Physics セクション](#22-physics-セクション)
    - [2.3 Nodes セクション](#23-nodes-セクション)
      - [2.3.1 ノード共通仕様](#231-ノード共通仕様)
      - [2.3.2 各ノード種別の詳細](#232-各ノード種別の詳細)
      - [2.3.3 MeshData.serialize の出力詳細](#233-meshdataserialize-の出力詳細)
    - [2.4 Param、Automation、Animations セクション](#24-paramautomationanimations-セクション)
      - [2.4.1 Param セクション](#241-param-セクション)
      - [2.4.2 Automation セクション](#242-automation-セクション)
      - [2.4.3 Animations セクション](#243-animations-セクション)
    - [2.5 パラメータバインディングの仕様](#25-パラメータバインディングの仕様)
      - [基本構文](#基本構文)
      - [共通の出力項目](#共通の出力項目)
      - [2.5.1 DeformationParameterBinding](#251-deformationparameterbinding)
      - [2.5.2 ParameterParameterBinding](#252-parameterparameterbinding)
      - [2.5.3 ValueParameterBinding](#253-valueparameterbinding)
  - [3. 階層構造とシリアライザの呼び出し](#3-階層構造とシリアライザの呼び出し)
  - [4. 出力フォーマット全体の特徴](#4-出力フォーマット全体の特徴)
  - [5. 仕様上の留意点](#5-仕様上の留意点)

---

# 1. INPバイナリフォーマット全体構造（実装仕様）

この章では、実際にINPファイル書き込み実装によって生成される**バイナリレイアウト**を正式に記述します。従来の「チャンクヘッダ＋オフセットテーブル」型の一般的説明に代わり、実装で用いられる**逐次ストリーミング構造**を定義します。

## 1.1 ファイル全体レイアウト

INPバイナリファイルは以下の**セグメントを順次ストリーム書き込み**で構成します。  
**グローバルなセクションテーブルやチャンクオフセットは存在しません。**

<pre>
INPファイル全体構造（擬似C構造体表記）:

struct INPFile {
    uint8_t  magic[8];         // "TRNSRTS\0" （8バイト固定）
    uint32_t jsonLength;       // JSONセクション長（バイト数、ビッグエンディアン）
    uint8_t  jsonData[jsonLength];  // UTF-8エンコードJSONデータ

    // テクスチャセクション（存在する場合のみ）
    uint8_t  texSectionID[8];  // "TEX_SECT"（8バイト固定）
    uint32_t texCount;         // テクスチャ数（ビッグエンディアン）
    TextureEntry textureEntries[texCount];

    // 拡張セクション（存在する場合のみ）
    uint8_t  extSectionID[8];  // "EXT_SECT"（8バイト固定）
    uint32_t extEntryCount;    // 拡張エントリ数（ビッグエンディアン）
    ExtEntry extEntries[extEntryCount];
}

struct TextureEntry {
    uint32_t dataLength;   // 画像バイト長（ビッグエンディアン）
    uint8_t  texType;      // 画像種別（例: IN_TEX_TGA）
    uint8_t  imageData[dataLength]; // 生画像データ
}

struct ExtEntry {
    uint32_t nameLength;     // ペイロード名の長さ（ビッグエンディアン）
    uint8_t  name[nameLength];   // UTF-8名
    uint32_t payloadLength;      // ペイロード長（ビッグエンディアン）
    uint8_t  payload[payloadLength]; // バイナリデータ
}
</pre>

- **セクションはストリーム順に連続出力されます。**（JSON→TEX_SECT→EXT_SECT、各データがある場合のみ）
- **グローバルなセクションテーブルやオフセット情報はありません。**
- **4バイトアライメントやリトルエンディアンは使用せず、長さフィールドは全て4バイト・ビッグエンディアンです。**

## 1.2 セクション識別子と構造

| セクション      | セクションID（バイト列） | 内容                | 出現条件                 |
|:--------------- |:------------------------|:--------------------|:------------------------|
| JSON           | なし                    | JSON（長さ付き）    | 常に（モデル本体）      |
| テクスチャ      | "TEX_SECT"（8バイト）   | テクスチャ画像      | テクスチャが存在する場合 |
| 拡張データ      | "EXT_SECT"（8バイト）   | 拡張ペイロード      | extData[]が非空の場合    |

- セクションID（"TEX_SECT"、"EXT_SECT"）は**8バイトASCII固定、パディング無し**。
- "JSON"にはセクションIDは無く、**先頭が必ずJSON長+JSONデータ**。

## 1.3 JSONセクション

- ファイル先頭から **最初のセクションはモデル情報JSON**（UTF-8バイト列）。
- JSONの長さ（バイト数）は**4バイトビッグエンディアン符号なし整数**で記述、その直後にJSONバイト列を配置。
- JSON内部の詳細仕様（構造・フィールド等）は本書第2章で定義。

## 1.4 テクスチャセクション（"TEX_SECT"）

- Puppetにテクスチャが含まれる場合、JSONセクション直後に**"TEX_SECT"**（8バイト）が出現。
- 直後に4バイトビッグエンディアンで**テクスチャ数**を記述。
- 各テクスチャは以下の順に連続して記述される:
    - 画像データ長（4バイトビッグエンディアン）
    - 画像種別（1バイト、例: IN_TEX_TGA）
    - 生画像データ（上記長さ分）

## 1.5 拡張セクション（"EXT_SECT"）

- extDataが存在する場合、（テクスチャセクションの後に）**"EXT_SECT"**（8バイト）が出現。
- 直後に4バイトビッグエンディアンで**拡張エントリ数**を記述。
- 各拡張エントリは以下の順に連続して記述される:
    - ペイロード名長（4バイトビッグエンディアン）
    - UTF-8名（上記長さ分）
    - ペイロード長（4バイトビッグエンディアン）
    - バイナリデータ（上記長さ分）

## 1.6 バージョン管理・拡張性

- **バイナリファイルのヘッダには明示的なバージョンフィールドはありません。**  
  バージョンはJSON内部の"meta.version"のみ。
- セクション種別やフィールドは順序・IDでのみ判別されます。
- 未知のセクションIDは現状なく、"TEX_SECT"と"EXT_SECT"のみ利用可。
- 拡張は末尾に新たな8バイトIDのセクション追加でのみ可能。

## 1.7 仕様駆動の「チャンクヘッダ」形式との比較

- **従来のトップレベルセクションテーブルやオフセット・長さ管理は使用されません。**
- セクション順序は**固定で暗黙**（JSON→テクスチャ→拡張）。
- 長さはすべて4バイト・ビッグエンディアン整数。
- セクションID（ある場合）はすべて8バイト。

---

## 2. トップレベル構造

### 2.1 Puppet構造（JSONルート）

出力されるJSONデータは、以下のキーを持つ単一のオブジェクト（Puppet）として生成されます。

```
Puppet ::= {
  "meta"       : Meta,              // メタ情報
  "physics"    : Physics,           // 物理設定
  "nodes"      : Node,              // ルートノード（子ノードを含むツリー構造）
  "param"      : [ Parameter, ... ],// パラメータ配列
  "automation" : [ Automation, ... ],// オートメーション配列
  "animations" : { ... }            // アニメーション連想配列
}
```

- **meta**: 全体のメタデータ（例: 名前、バージョン、制作者情報等）。
- **physics**: 物理パラメータ（例: pixelsPerMeter, gravity）。
- **nodes**: ルートノード（Nodeオブジェクト）。子ノードを持つツリー構造。
- **param**: パラメータ配列（Parameter[]）。
- **automation**: オートメーション配列（Automation[]）。
- **animations**: アニメーション連想配列（Animation[string]）。

---

### 2.2 Meta セクション

**目的:** 全体のメタ情報を提供する

**文法:**

```
Meta ::= {
  "name"        : String,   // モデル名
  "version"     : String,   // Nijilive仕様バージョン
  "rigger"      : String,   // リガー（省略可）
  "artist"      : String,   // アーティスト（省略可）
  "rights"      : {         // 利用権情報（省略可）
    "allowedUsers": String,
    "allowViolence": Boolean,
    "allowSexual": Boolean,
    "allowCommercial": Boolean,
    "allowRedistribution": String,
    "allowModification": String,
    "requireAttribution": Boolean
  },
  "copyright"   : String,   // 著作権表記（省略可）
  "licenseURL"  : String,   // ライセンスURL（省略可）
  "contact"     : String,   // 連絡先（省略可）
  "reference"   : String,   // 参照URL等（省略可）
  "thumbnailId" : Number,   // サムネイルテクスチャID（省略可）
  "preservePixels": Boolean // ピクセル境界維持（省略可）
}
```

---

### 2.2 Physics セクション

**目的:** 物理演算に関する基礎パラメータの定義

**文法:**

```
Physics ::= {
  "pixelsPerMeter": Number, // 1メートルあたりのピクセル数
  "gravity": Number         // 重力加速度
}
```

---

### 2.3 Nodes セクション

**目的:** 描画オブジェクト及び構造体の定義と、階層構造の表現

#### 2.3.1 ノード共通仕様

各ノードは以下の基本プロパティを持ち、必要に応じ子ノードや変換情報を追加する.

```
Node ::= {
  "uuid"        : Number,                // ノード固有識別子
  "name"        : String,                // ノード名
  "type"        : String,                // ノード種別 (例: "Drawable", "Composite" 等)
  "enabled"     : Boolean,               // 有効状態
  "zsort"       : Number,                // 描画順序
  "transform"   : Transform,             // ローカル変換情報
  "lockToRoot"  : Boolean,               // ルートへのロック
  "pinToMesh"   : Boolean,               // メッシュへのピン止め
  [ "children"  : [ Node, ... ] ]        // 子ノード配列（再帰的ネスト、TmpNodeは除外）
}
```

**Transform の文法:**

```
Transform ::= {
  "trans" : [ Number, Number, Number ], // 平行移動ベクトル (vec3)
  "rot"   : [ Number, Number, Number ], // 回転ベクトル (vec3, オイラー角)
  "scale" : [ Number, Number ]          // スケールベクトル (vec2)
}
```

#### 2.3.2 各ノード種別の詳細

各ノード種別は、共通仕様に加え以下の固有プロパティを持つ.

- **Drawable ノード**  
  ```
  Drawable ::= Node  where "type" = "Drawable" and then {
    "mesh": MeshDataSerialize,
    [ "weldedLinks": [ WeldingLink, ... ] ] // 省略可
  }
  ```
  - 備考: `serializeSelf` により出力されるメッシュ情報は、セクション 2.3.3 に定義する形式に従う。weldedLinksは他Drawableとの溶接情報（存在する場合のみ）。

**WeldingLink の詳細:**
```
WeldingLink ::= {
  "targetUUID": Number,         // 溶接先Drawableノードのuuid
  "indices": [ Number, ... ],   // 溶接頂点インデックス配列（自身の頂点→targetの頂点対応, -1は未対応）
  "weight": Number              // 溶接の重み（0.0～1.0）
}
```

- **Composite ノード**  
  ```
  Composite ::= Node where "type" = "Composite" and then {
    "blend_mode"      : String,
    "tint"            : Color,
    "screenTint"      : Color,
    "mask_threshold"  : Number,
    "opacity"         : Number,
    "propagate_meshgroup": Boolean,
    [ "masks": [ MaskBinding, ... ] ] // 省略可
  }
  ```
  - 備考: masksはMaskBinding型の配列（存在する場合のみ）。tint/screenTintはvec3、mask_thresholdはNumber、propagate_meshgroupはBoolean。

**MaskBinding の詳細:**
```
MaskBinding ::= {
  "maskSrcUUID": Number,   // マスク元Drawableノードのuuid
  "mode": String           // マスクモード（例: "Mask", "DodgeMask" など）
}
```

- **DynamicComposite ノード**  
  ```
  DynamicComposite ::= Part  where "type" = "DynamicComposite" and then {
    "auto_resized": Boolean // 自動リサイズメッシュかどうか
  }
  ```
  - 備考: Partノードの全フィールド（textures, blend_mode, tint, ...）に加え、auto_resized（Boolean）が追加される。

- **Part ノード**  
  ```
  Part ::= Drawable where "type" = "Part" and then {
    "textures": [ Number, ... ],
    "blend_mode": String,
    "tint": Color,
    "screenTint": Color,
    "emissionStrength": Number,
    "masks": [ Mask, ... ],
    "mask_threshold": Number,
    "opacity": Number,
    "textureUUIDs": [ String, ... ],
    "meshData": MeshDataSerialize
  }
  ```
  - 備考: Drawableノードの全フィールド（mesh, weldedLinks等）に加え、Part固有のフィールドが追加される。

- **SimplePhysics ノード**  
  ```
  SimplePhysics ::= Node where "type" = "SimplePhysics" and then {
    "type"             : String,   // 物理モデル種別（例: "Pendulum", "SpringPendulum" など）
    "damping"          : Number,   // 減衰係数
    "restore_constant" : Number,   // 復元力定数
    "gravity"          : Number,   // 重力加速度
    "input_scale"      : Number,   // 入力スケール
    "propagate_scale"  : Number    // 伝播スケール
    // SpringPendulum等、他モデルでは追加パラメータが出力される場合がある
  }
  ```
  - 備考: 実装上、typeは"Pendulum"や"SpringPendulum"など物理モデル名となる。現状SpringPendulumの追加パラメータは未出力。

- **MeshGroup ノード**  
  ```
  MeshGroup ::= Drawable  where "type" = "MeshGroup" and then {
    "dynamic_deformation": Boolean,
    "translate_children": Boolean
  }
  ```
  - 備考: Drawableノードの全フィールド（mesh, weldedLinks等）に加え、dynamic_deformation, translate_childrenが追加される。gridフィールドは現行実装では出力されない。


- **Deformable ノード**  
  ```
  Deformableは抽象クラスであり、type: "Deformable"として直接出力されることはありません。実際の出力はPartやMask、MeshGroup、PathDeformer等の具象クラスで行われます。
  ```

- **PathDeformer ノード**  
  ```
  PathDeformer ::= Node where "type" = "PathDeformer" and then {
    "physics_only" : Boolean,         // 物理演算のみ有効か（省略可）
    "curve_type"   : String,          // "Bezier" または "Spline"
    "vertices"     : [ Number, ... ], // 各頂点のx, y座標を交互に格納した配列
    [ "physics"    : {                // 物理ドライバ情報（存在する場合のみ）
         "type"             : String,
         "damping"          : Number,
         "restore_constant" : Number,
         "gravity"          : Number,
         "input_scale"      : Number,
         "propagate_scale"  : Number
      } ]
  }
  ```
  - 備考: 物理ドライバ情報は"physics"キーで出力され、typeは"Pendulum"や"SpringPendulum"など。verticesは[x, y, x, y, ...]形式。

- **Mask ノード**  
  ```
  Maskノードはtype: "Mask"のNodeとして出力されます。idやmode、thresholdといったフィールドは持たず、出力内容はDrawableノードと同様でmesh等の情報を持ちます。
  ```

- **Puppet 構造**  
  ```
  Puppet ::= {
    "meta"       : Meta,
    "physics"    : Physics,
    "nodes"      : [ Node, ... ],
    "param"      : ParamSection,
    "automation" : AutomationSection,
    "animations" : AnimationsSection
  }
  ```
  - 備考: 各セクションを統合し、出力全体の整合性を保証する.

#### 2.3.3 MeshData.serialize の出力詳細

MeshData.serialize の結果は、下記の形式に従って JSON オブジェクトとして出力される:

```
MeshDataSerialize ::= "{" 
    "\"verts\""     ":" NumberList
    [ "," "\"uvs\"" ":" NumberList ]
    "," "\"indices\"" ":" NumberList
    "," "\"origin\""  ":" [ Number, Number ]
    [ "," "\"grid_axes\"" ":" GridAxesObject ]
  "}"
  
NumberList      ::= "[" { Number [ "," ] } "]"
OriginObject    ::= "{" "\"x\"" ":" Number "," "\"y\"" ":" Number "}"
GridAxesObject  ::= "[" NumberList "," NumberList "]"
```

- **"verts"**: 各頂点の x, y 座標が、連続した数値リストとして出力される。
- **"uvs"**: (任意) 各頂点の u, v 座標が、連続した数値リストとして出力される。UV 情報が存在しない場合、このキーは省略される。
- **"indices"**: 頂点接続情報のインデックスリスト。
- **"origin"**: メッシュ原点を示すオブジェクト。
- **"grid_axes"**: (任意) グリッドメッシュの場合、各軸の値リストが2つの NumberList として出力される。

---

### 2.4 Param、Automation、Animations セクション

#### 2.4.1 Param セクション

Param セクションは、各パラメータごとに下記のようなオブジェクト配列として出力されます。  
各パラメータは `serializeSelf` の実装に従い、以下の順序・構造で出力されます。

```json
[
  {
    "uuid": String,                // パラメータ固有ID
    "name": String,                // パラメータ名
    "is_vec2": Boolean,            // 2次元パラメータかどうか
    "min": Number | [Number, Number],   // 最小値（スカラーまたは2要素配列）
    "max": Number | [Number, Number],   // 最大値（スカラーまたは2要素配列）
    "defaults": Number | [Number, Number], // デフォルト値（スカラーまたは2要素配列）
    "axis_points": [ [Number,...], [Number,...] ],   // 軸点リスト（1次元: [値...], 2次元: [ [値...], [値...] ]）
    "merge_mode": String,          // マージモード
    "bindings": [
      {
        ... // 各バインディングのシリアライズ結果（2.5節参照）
      },
      ...
    ]
  },
  ...
]
```

- 各フィールドは `serializeSelf` の呼び出し順に従い、必ず出力されます。
- `min`, `max`, `defaults` はスカラーまたはオブジェクト（vec2）で出力されます。
- `axis_points` は数値配列、`merge_mode` は文字列です。
- `bindings` はバインディングオブジェクトの配列で、各要素は `binding.serializeSelf` の出力（2.5節参照）です。

**例:**
```json
[
  {
    "uuid": "xxxx-xxxx-xxxx-xxxx",
    "name": "ParamA",
    "is_vec2": false,
    "min": 0.0,
    "max": 1.0,
    "defaults": 0.5,
    "axis_points": [[0.0, 0.5, 1.0], [0.0]],

    // 2次元パラメータ例
    // "min": [0.0, 0.0],
    // "max": [1.0, 1.0],
    // "defaults": [0.5, 0.5],
    // "axis_points": [[0.0, 0.5, 1.0], [0.0, 1.0]],
    "merge_mode": "replace",
    "bindings": [
      {
        "node": "Node1",
        "param_name": "deform",
        "values": [0.0, 1.0, 0.5],
        "isSet": true
      }
    ]
  }
]
```

#### 2.4.2 Automation セクション

```
AutomationSection ::= {
  "param": String,
  "axis" : String,
  "range": [ Number, Number ]
}
```

#### 2.4.3 Animations セクション

```
AnimationsSection ::= {
  "timestep" : Number,
  "leadIn"   : Number,
  "leadOut"  : Number,
  "keyframes": [ { "time": Number, "value": Number }, ... ]
  // 実装上は以下の追加フィールドも出力される:
  // "additive": Boolean,           // 加算アニメーションかどうか
  // "animationWeight": Number,     // 加算アニメーション時の重み
  // "length": Number,              // アニメーション全体のフレーム数
  // "lanes": [ ... ]               // 各パラメータ・軸ごとのアニメーションレーン
}
```
- 備考: 実装では "lanes" 配下に "interpolation"（補間モード）, "uuid"（パラメータUUID）, "target"（軸番号）, "keyframes"（各キーフレーム）, "merge_mode" などが含まれる。  
  各 "keyframes" は "frame"（フレーム番号）, "value"（値）, "tension"（補間テンション）を持つ。
  これらの追加フィールドはアニメーションの詳細制御や拡張性のために利用される。

---

### 2.5 パラメータバインディングの仕様

#### 基本構文

```
Parameter ::= {
  "name"    : String,
  "min"     : Number | [Number, Number],      // スカラーまたは2要素配列
  "max"     : Number | [Number, Number],      // スカラーまたは2要素配列
  "default" : Number | [Number, Number],      // スカラーまたは2要素配列
  "binding" : ParameterBinding
}
```

#### 共通の出力項目

ParameterBinding は以下の項目を必ず出力する:

```
ParameterBinding ::= {
  "node"            : String,
  "param_name"      : String,
  "values"          : NumberList | [ [Number, ...], ... ], // 1次元: [値...], 2次元: [ [値...], ... ]
  "isSet"           : Boolean,
  [ "interpolate_mode": String ]
}
```

#### 2.5.1 DeformationParameterBinding
（適用: "param_name" = "deform"）

```
DeformationParameterBinding ::= ParameterBinding extended by {
  "deformation_strength": Number,
  "deformation_offset"  : Number,
  "deformation_unit"    : String
}
```

#### 2.5.2 ParameterParameterBinding
（適用: "param_name" = "X" または "Y"、または数値インデックス 0,1）

```
ParameterParameterBinding ::= ParameterBinding extended by {
  "target_uuid" : String,
  "target_name" : String
}
```

#### 2.5.3 ValueParameterBinding
（その他の場合）

```
ValueParameterBinding ::= ParameterBinding extended by {
  "value" : Number
}
```

---

## 3. 階層構造とシリアライザの呼び出し

- **ノードのネスト:**  
  各ノードは `serializeSelfImpl` 内で子ノードを再帰的にシリアライズする。これにより、Composite、DynamicComposite、Part 等は個別のシリアライザを呼び出し、最終的に Puppet 構造として統合される.
- **統合:**  
  各主要セクション（meta、physics、nodes、param、automation、animations）は、最終的に Puppet オブジェクトで統合し、出力全体の整合性を保証する.

---

## 4. 出力フォーマット全体の特徴

- **有効な JSON:**  
  各フィールドはキーと対応する値によって厳密に定義される.
- **階層構造:**  
  ノードは再帰的な親子関係を形成し、複雑なオブジェクト階層を表現できる.
- **拡張性:**  
  ParameterBinding の実装により、将来の仕様拡張や変形情報の追加に対応可能.

---

## 5. 仕様上の留意点

- 各シリアライザは親子間の呼び出し規則と整合性を厳守する必要がある.
- ParameterBinding では、全ての共通項目および派生固有項目が出力され、deserialize 時に正確な型へ再構築されることが求められる.
- 各セクションは独立性を維持しつつ、全体として統一されたフォーマットとなる.
