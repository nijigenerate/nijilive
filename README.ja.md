<p align="center">
  <img width="256" height="256" src="https://raw.githubusercontent.com/nijilive/branding/main/logo/logo_transparent_256.png">
</p>

# nijilive
[![Support me on Patreon](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fshieldsio-patreon.vercel.app%2Fapi%3Fusername%3Dclipsey%26type%3Dpatrons&style=for-the-badge)](https://patreon.com/clipsey)
[![Discord](https://img.shields.io/discord/855173611409506334?label=Community&logo=discord&logoColor=FFFFFF&style=for-the-badge)](https://discord.com/invite/abnxwN6r9v)

nijiliveはリアルタイム2Dパペットアニメーションライブラリで、nijilivePuppetスタンダードのリファレンス実装です。nijiliveはレイヤーに分割された絵から作成されたメッシュを、実行時にパラメーターに基づいて変形させ、視聴者に奥行きと動きを感じさせます。

&nbsp;

https://user-images.githubusercontent.com/7032834/166389697-02eeeedb-6a44-4570-9254-f6aa4f095300.mp4

*Beta 0.7.2を使用。VTuber：[LunaFoxgirlVT](https://twitter.com/LunaFoxgirlVT)、イラストレーター：[kpon](https://twitter.com/kawaiipony2)*

&nbsp;

# モデラーまたはVTuber様へ
あなたがモデラーなら、ぜひこちらをご覧ください。  
開発中の公式nijiliveモデリングアプリ [nijigenerate](https://github.com/nijigenerate/nijigenerate)  

あなたがVTuberなら、ぜひこちらをご覧ください。  
[Inochi Session](https://github.com/nijigenerate/nijiexpose)  

注：このリポジトリはスタンダード専用です。エンドユーザー向けのものではありません。

&nbsp;

# ドキュメント
現在、仕様と公式ツール群に関するドキュメントの執筆中です。[こちら](https://docs.github.com/nijigenerate)から公式ドキュメントをご覧いただけます。

&nbsp;

# サポート対象のプラットフォーム

このリファレンス実装は、動作にOpenGL 3.1コンテキストを必要とします。また、OpenGL 3.1(または以降のバージョン)のコンテキストが確立された後に`inInit`が呼び出されるべきです。

私たちは、開発者が任意のバックエンドを接続できるように、レンダリング機能をフロントエンドから分離することに取り組むつもりです。私たちは、D言語以外からこのライブラリを使用する方法として[nijilive-c](https://github.com/nijigenerate/nijilive-c)を提供し、さらに2つ目のワークグループが、[Inox2D](https://github.com/nijigenerate/inox2d)でnijilive仕様の純粋なRust実装を開発しています。

&nbsp;

---

nijiliveのロゴは[James Daniel](https://twitter.com/rakujira)氏によってデザインされました。
