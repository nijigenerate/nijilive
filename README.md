<p align="center">
  <img width="256" height="256" src="https://github.com/nijigenerate/nijilive/assets/449741/40222ef8-4327-457b-96d5-199e12c93104">
</p>
<!--
[日本語](https://github.com/nijigenerate/nijilive/blob/main/README.ja.md)
[简体中文](https://github.com/nijigenerate/nijilive/blob/main/README.zh.md)
-->

# nijilive
<!--[![Support me on Patreon](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fshieldsio-patreon.vercel.app%2Fapi%3Fusername%3Dclipsey%26type%3Dpatrons&style=for-the-badge)](https://patreon.com/clipsey)
[![Discord](https://img.shields.io/discord/855173611409506334?label=Community&logo=discord&logoColor=FFFFFF&style=for-the-badge)](https://discord.com/invite/abnxwN6r9v)
-->
nijilive is a library for realtime 2D puppet animation and the reference implementation of the nijilive Puppet standard. nijilive works by deforming 2D meshes created from layered art at runtime based on parameters, this deformation tricks the viewer in to seeing 3D depth and movement in the 2D art.

&nbsp;


https://github.com/nijigenerate/nijilive/assets/449741/7794ea4f-cce0-4b0b-9078-e1f17ae3de98


*Video from nijilive + nijiexpose 0.0.1, model by seagetch*

&nbsp;

# For Riggers and VTubers
If you're a model rigger you may want to check out [nijigenerate](https://github.com/nijigenerate/nijigenerate), the official nijilive rigging app in development.
If you're a VTuber you may want to check out [nijiexpose](https://github.com/nijigenerate/nijiexpose).
This repository is purely for the standard and is not useful if you're an end user.

&nbsp;

# Documentation
Documentation is currently in the process of being written for the spec and the official tools. You can find the official documentation page [here](https://docs.github.com/nijigenerate).

&nbsp;

# Supported platforms
The reference implementation available here currently requires a OpenGL 3.1 context to function, `inInit` should be called *after* a OpenGL 3.1 (or higher) context has been established.

~~We will be working on splitting the rendering out from the frontend, so that developers can plug their own backend in. We provide [nijilive-c](https://github.com/nijigenerate/nijilive-c) as a way to use this library from non-D languages.~~

&nbsp;


---

The nijilive logo was designed by [seagetch](https://twitter.com/seagetch) with DALL-E3 assistance.
