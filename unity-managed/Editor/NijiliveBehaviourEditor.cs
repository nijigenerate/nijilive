#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;

namespace Nijilive.Unity.Managed.Editor
{
    [CustomEditor(typeof(NijiliveBehaviour))]
    public sealed class NijiliveBehaviourEditor : UnityEditor.Editor
    {
        SerializedProperty _puppetPath;
        SerializedProperty _viewport;
        SerializedProperty _partMat;
        SerializedProperty _compositeMat;
        SerializedProperty _propertyConfig;
        SerializedProperty _textureBindings;

        void OnEnable()
        {
            _puppetPath = serializedObject.FindProperty(nameof(NijiliveBehaviour.PuppetPath));
            _viewport = serializedObject.FindProperty(nameof(NijiliveBehaviour.Viewport));
            _partMat = serializedObject.FindProperty(nameof(NijiliveBehaviour.PartMaterial));
            _compositeMat = serializedObject.FindProperty(nameof(NijiliveBehaviour.CompositeMaterial));
            _propertyConfig = serializedObject.FindProperty(nameof(NijiliveBehaviour.PropertyConfig));
            _textureBindings = serializedObject.FindProperty(nameof(NijiliveBehaviour.TextureBindings));
        }

        public override void OnInspectorGUI()
        {
            serializedObject.Update();

            EditorGUILayout.LabelField("Nijilive Renderer", EditorStyles.boldLabel);
            using (new EditorGUILayout.HorizontalScope())
            {
                EditorGUILayout.PropertyField(_puppetPath, new GUIContent("Puppet Path"));
                if (GUILayout.Button("Browse", GUILayout.Width(70)))
                {
                    var path = EditorUtility.OpenFilePanel("Select Puppet (.inp/.inx)", Application.dataPath, "inp,inx");
                    if (!string.IsNullOrEmpty(path))
                    {
                        _puppetPath.stringValue = path;
                    }
                }
                if (GUILayout.Button("Reload", GUILayout.Width(70)))
                {
                    foreach (var targetObj in targets)
                    {
                        if (targetObj is NijiliveBehaviour nb)
                        {
                            nb.ReloadPuppet();
                            EditorUtility.SetDirty(nb);
                        }
                    }
                }
            }
            EditorGUILayout.PropertyField(_viewport, new GUIContent("Viewport (0=Screen)"));
            EditorGUILayout.PropertyField(_partMat);
            EditorGUILayout.PropertyField(_compositeMat);

            EditorGUILayout.Space();
            EditorGUILayout.LabelField("Property Config", EditorStyles.boldLabel);
            DrawPropertyConfig(_propertyConfig);

            EditorGUILayout.Space();
            EditorGUILayout.PropertyField(_textureBindings, true);

            serializedObject.ApplyModifiedProperties();
        }

        private void DrawPropertyConfig(SerializedProperty prop)
        {
            if (prop == null) return;
            var iterator = prop.Copy();
            var end = iterator.GetEndProperty();
            iterator.NextVisible(true);
            while (!SerializedProperty.EqualContents(iterator, end))
            {
                EditorGUILayout.PropertyField(iterator, true);
                if (!iterator.NextVisible(false)) break;
            }
        }
    }
}
#endif
