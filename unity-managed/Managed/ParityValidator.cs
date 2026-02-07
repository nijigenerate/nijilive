using System;
using System.Collections.Generic;
using System.Linq;

namespace Nijilive.Unity.Managed
{
    /// <summary>
    /// Light-weight parity checker that validates decoded command streams for structural issues
    /// (balanced dynamic composite scopes, mask ordering, texture counts) before Unity playback.
    /// This is a managed-side sanity check; it does not compare rendered pixels.
    /// </summary>
    public static class ParityValidator
    {
        public sealed record ParityReport(bool IsValid, IReadOnlyList<string> Issues)
        {
            public override string ToString() => IsValid
                ? "Parity validation passed."
                : "Parity validation failed: " + string.Join("; ", Issues);
        }

        public static ParityReport Validate(IReadOnlyList<CommandStream.Command> commands)
        {
            var issues = new List<string>();
            var dynStack = new Stack<CommandStream.DynamicCompositePass>();
            var maskDepth = 0;
            foreach (var cmd in commands ?? Array.Empty<CommandStream.Command>())
            {
                switch (cmd)
                {
                    case CommandStream.BeginDynamicComposite begin:
                        dynStack.Push(begin.Pass);
                        if (begin.Pass?.Textures.Length == 0)
                        {
                            issues.Add("BeginDynamicComposite without textures");
                        }
                        break;
                    case CommandStream.EndDynamicComposite end:
                        if (dynStack.Count == 0)
                        {
                            issues.Add("EndDynamicComposite without matching begin");
                        }
                        else
                        {
                            var start = dynStack.Pop();
                            if (!ReferenceEquals(start, null) && !ReferenceEquals(end.Pass, null))
                            {
                                if (start.Textures.Length != end.Pass.Textures.Length)
                                {
                                    issues.Add("DynamicComposite texture count mismatch between begin/end");
                                }
                                if (start.Stencil != end.Pass.Stencil)
                                {
                                    issues.Add("DynamicComposite stencil mismatch between begin/end");
                                }
                            }
                        }
                        break;
                    case CommandStream.BeginMask:
                        maskDepth++;
                        break;
                    case CommandStream.BeginMaskContent:
                        if (maskDepth <= 0) issues.Add("BeginMaskContent without BeginMask");
                        break;
                    case CommandStream.EndMask:
                        if (maskDepth <= 0) issues.Add("EndMask without BeginMask");
                        else maskDepth--;
                        break;
                    case CommandStream.ApplyMask apply:
                        if (maskDepth <= 0) issues.Add("ApplyMask outside mask scope");
                        if (apply.Apply.Kind == Interop.NijiliveNative.MaskDrawableKind.Mask &&
                            apply.Apply.Mask.VertexCount == 0)
                        {
                            issues.Add("ApplyMask (Mask) has zero vertices");
                        }
                        if (apply.Apply.Kind == Interop.NijiliveNative.MaskDrawableKind.Part &&
                            apply.Apply.Part.VertexCount == 0)
                        {
                            issues.Add("ApplyMask (Part) has zero vertices");
                        }
                        break;
                    case CommandStream.DrawPart draw:
                        if (!draw.Part.Renderable) issues.Add("DrawPart marked non-renderable");
                        if (draw.Part.VertexCount == 0 || draw.Part.IndexCount == 0)
                        {
                            issues.Add("DrawPart has empty geometry");
                        }
                        break;
                }
            }
            if (dynStack.Count > 0) issues.Add($"Unclosed DynamicComposite scopes: {dynStack.Count}");
            if (maskDepth != 0) issues.Add("Mask scopes not balanced");
            return new ParityReport(issues.Count == 0, issues);
        }
    }
}
