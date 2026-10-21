using System;
using System.IO;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEditor;
using Nicxlive.UnityBackend.Managed;
public static class CompatibilityRenderTest {
 public static void Run() {
  try {
   var registry=new TextureRegistry();
   using(var renderer=new NicxliveRenderer(512,512,registry)) {
    renderer.LoadPuppet(Environment.GetEnvironmentVariable("NIJI_UNITY_MODEL"));
    renderer.SetPuppetScale(.09f,-.09f); renderer.SetPuppetTranslation(0,0);
    var camera=new GameObject("CompatibilityCamera").AddComponent<Camera>();
    var target=new RenderTexture(512,512,24,RenderTextureFormat.ARGB32);target.Create();camera.targetTexture=target;
    var partShader=Shader.Find("Nicxlive/URP Part");var maskShader=Shader.Find("Nicxlive/URP Mask");
    if(partShader==null || maskShader==null || !partShader.isSupported || !maskShader.isSupported)throw new Exception("Common shaders unavailable");
    var part=new Material(partShader);var mask=new Material(maskShader);var executor=new CommandExecutor();
    using(var commands=new CommandBuffer()) {
     renderer.BeginFrame(512,512);renderer.Tick(1.0/60);
     var decoded=CommandStream.Decode(renderer.EmitCommands());var shared=renderer.GetSharedBuffers();
     if(decoded.Count==0)throw new Exception("No model commands");
     executor.Execute(commands,camera,decoded,shared,registry,part,mask,new CommandExecutor.PropertyConfig());
     Graphics.ExecuteCommandBuffer(commands);
     RenderTexture.active=target;var image=new Texture2D(512,512,TextureFormat.RGBA32,false);image.ReadPixels(new Rect(0,0,512,512),0,0);image.Apply();
     int visible=0;foreach(var pixel in image.GetPixels32())if(pixel.a>0)visible++;
     File.WriteAllBytes(Environment.GetEnvironmentVariable("NIJI_UNITY_IMAGE"),image.EncodeToPNG());
     RenderTexture.active=null;
     if(visible<100)throw new Exception("Rendered image is empty");
     Debug.Log("COMPATIBILITY PASS commands="+decoded.Count+" visiblePixels="+visible);
    }
   }
   EditorApplication.Exit(0);
  } catch(Exception ex) {Debug.LogException(ex);EditorApplication.Exit(1);}
 }
}
