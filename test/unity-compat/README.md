# Unity compatibility verification

`main.cpp` is compiled against the supplied nicxlive checkout's actual public
header, then dynamically loads the nijilive DLL. It checks every exported symbol,
all layout-query offsets/sizes, and optionally exercises a real INP over three
frames, with callback tracking, resize, two renderers and unload validation.
See `unity-managed/README.md` for build/run commands.

`managed/AbiTest.csproj` validates the actual managed P/Invoke declarations.
Requires .NET 9 SDK for the test runner (the library targets netstandard2.1).

For GPU verification, install the shared nicxlive host into an isolated Unity URP
project using `unity-managed/install-nicxlive-host.ps1`, copy `UnityRenderTest.cs`
into `Assets/Editor/CompatibilityRenderTest.cs`, set `NIJI_UNITY_MODEL` to the INP
and `NIJI_UNITY_IMAGE` to an output PNG, and run Unity with:

```
-batchmode -projectPath <project> -executeMethod CompatibilityRenderTest.Run -logFile <log>
```

The fixture uses a 512px target and a 0.09 scale suited to the Kurone test model.
The Y sign compensates the target's orientation. Adjust the fixture transform for
other model extents. The production runtime and shaders are copied unmodified.
The test requires real GPU graphics (do not use `-nographics`). It fails on empty
commands or an empty render target, writes the PNG for visual inspection and exits.

Verified on Windows with LDC 1.41, MSVC and Unity 6000.2.13f1 using
`Kurone-20240212-1.4-wld7.1.inp`: 148 commands, 127 geometry draws, 5795 vertices.
