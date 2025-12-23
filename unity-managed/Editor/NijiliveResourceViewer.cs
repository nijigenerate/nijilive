using System.Collections.Generic;
using Nijilive.Unity.Managed;
#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;
#endif

namespace Nijilive.Unity.Managed.Editor
{
#if UNITY_EDITOR
    /// <summary>
    /// Simple editor window to inspect textures registered in Nijilive's TextureRegistry.
    /// Helps verify that native-created textures are visible on the managed/Unity side.
    /// </summary>
    public sealed class NijiliveResourceViewer : EditorWindow
    {
        private NijiliveBehaviour _target;
        private Vector2 _scroll;

        [MenuItem("Nijilive/Resource Viewer")]
        public static void Open()
        {
            GetWindow<NijiliveResourceViewer>("Nijilive Resources");
        }

        private void OnGUI()
        {
            EditorGUILayout.LabelField("Nijilive Resource Viewer", EditorStyles.boldLabel);

            _target = (NijiliveBehaviour)EditorGUILayout.ObjectField(
                "Target Behaviour",
                _target,
                typeof(NijiliveBehaviour),
                true);

            if (_target == null)
            {
                if (GUILayout.Button("Pick First NijiliveBehaviour in Scene"))
                {
                    _target = FindObjectOfType<NijiliveBehaviour>();
                }
                return;
            }

            var renderer = _target.Renderer;
            if (renderer == null)
            {
                EditorGUILayout.HelpBox("Renderer is not ready yet.", MessageType.Info);
                return;
            }

            var registry = renderer.TextureRegistry;
            if (registry == null)
            {
                EditorGUILayout.HelpBox("TextureRegistry is null.", MessageType.Info);
                return;
            }

            EditorGUILayout.Space();
            EditorGUILayout.LabelField("Registered Textures:", EditorStyles.boldLabel);

            _scroll = EditorGUILayout.BeginScrollView(_scroll);
            foreach (KeyValuePair<nuint, ITextureBinding> entry in registry.Enumerate())
            {
                GUILayout.BeginHorizontal();
                EditorGUILayout.LabelField($"Handle {entry.Key}", GUILayout.Width(120));

                Object texObj = null;
                if (entry.Value != null)
                {
                    texObj = entry.Value.NativeObject as Object;
                }

                EditorGUILayout.ObjectField(texObj, typeof(Texture), false);
                GUILayout.EndHorizontal();
            }
            EditorGUILayout.EndScrollView();
        }
    }
#endif
}

