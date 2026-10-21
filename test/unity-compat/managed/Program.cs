using System;
using System.Runtime.InteropServices;
using Nijilive.Unity.Interop;
NativeLibrary.SetDllImportResolver(typeof(NijiliveNative).Assembly, (name, assembly, path) => NativeLibrary.Load(args[0]));
AbiValidator.ValidateOrThrow();
Console.WriteLine("PASS managed ABI size/offset validation");
