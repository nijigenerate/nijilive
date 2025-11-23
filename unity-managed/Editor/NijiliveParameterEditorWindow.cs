#if UNITY_EDITOR
using System.Collections.Generic;
using System.Linq;
using UnityEditor;
using UnityEngine;

namespace Nijilive.Unity.Managed.Editor
{
    /// <summary>
    /// Simple editor window that lists puppet parameters and lets you edit 1D/2D values.
    /// Requires a NijiliveBehaviour with an active renderer/puppet (typically in Play Mode).
    /// </summary>
    public sealed class NijiliveParameterEditorWindow : EditorWindow
    {
        private NijiliveBehaviour _target;
        private readonly List<ParameterDescriptor> _parameters = new();
        private readonly Dictionary<uint, Vector2> _values = new();
        private Vector2 _scroll;

        [MenuItem("Nijilive/Parameter Editor")]
        public static void Open()
        {
            GetWindow<NijiliveParameterEditorWindow>("Nijilive Params");
        }

        private void OnEnable()
        {
            TrySelectFromActive();
            RebuildParameterList();
        }

        private void OnSelectionChange()
        {
            TrySelectFromActive();
            Repaint();
        }

        private void OnGUI()
        {
            EditorGUILayout.LabelField("Target", EditorStyles.boldLabel);
            _target = (NijiliveBehaviour)EditorGUILayout.ObjectField(_target, typeof(NijiliveBehaviour), true);

            if (_target == null)
            {
                EditorGUILayout.HelpBox("Select a GameObject with a NijiliveBehaviour.", MessageType.Info);
                return;
            }
            if (_target.Renderer == null || _target.Puppet == null)
            {
                EditorGUILayout.HelpBox("Renderer is not ready yet. Enter Play Mode or ensure the puppet is loaded.", MessageType.Warning);
                if (GUILayout.Button("Refresh")) RebuildParameterList();
                return;
            }

            if (_parameters.Count == 0)
            {
                if (GUILayout.Button("Load Parameters"))
                {
                    RebuildParameterList();
                }
                return;
            }

            using (var scroll = new EditorGUILayout.ScrollViewScope(_scroll))
            {
                _scroll = scroll.scrollPosition;
                foreach (var p in _parameters)
                {
                    DrawParameter(p);
                    EditorGUILayout.Space(4);
                }
            }

            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Apply"))
                {
                    ApplyValues();
                }
                if (GUILayout.Button("Reload"))
                {
                    RebuildParameterList();
                }
            }
        }

        private void DrawParameter(ParameterDescriptor p)
        {
            EditorGUILayout.LabelField($"{p.Name} ({p.Uuid})", EditorStyles.boldLabel);
            var current = _values.TryGetValue(p.Uuid, out var val) ? val : ToVec2(p.Defaults);

            if (p.IsVec2)
            {
                current.x = EditorGUILayout.Slider("X", current.x, p.Min.X, p.Max.X);
                current.y = EditorGUILayout.Slider("Y", current.y, p.Min.Y, p.Max.Y);
            }
            else
            {
                current.x = EditorGUILayout.Slider("Value", current.x, p.Min.X, p.Max.X);
            }

            _values[p.Uuid] = current;
        }

        private void ApplyValues()
        {
            if (_target?.Puppet == null) return;
            var updates = _values.Select(kv => new NijiliveNative.PuppetParameterUpdate
            {
                ParameterUuid = kv.Key,
                Value = kv.Value.x,
            }).ToArray();

            _target.Puppet.UpdateParameters(updates);
        }

        private void RebuildParameterList()
        {
            _parameters.Clear();
            _values.Clear();
            if (_target?.Puppet == null) return;
            foreach (var p in _target.Puppet.GetParameters())
            {
                _parameters.Add(p);
                _values[p.Uuid] = ToVec2(p.Defaults);
            }
        }

        private void TrySelectFromActive()
        {
            if (Selection.activeGameObject != null)
            {
                _target = Selection.activeGameObject.GetComponent<NijiliveBehaviour>();
            }
        }

        private static Vector2 ToVec2(NijiliveNative.Vec2 v) => new Vector2(v.X, v.Y);
    }
}
#endif
