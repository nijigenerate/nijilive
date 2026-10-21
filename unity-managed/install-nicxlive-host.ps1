param(
    [Parameter(Mandatory=$true)][string]$UnityProjectPath,
    [string]$NicxliveSourcePath = (Join-Path $PSScriptRoot '../../nicxlive'),
    [string]$NativeDll = (Join-Path $PSScriptRoot '../nijilive-unity.dll')
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath($UnityProjectPath)
$source = [IO.Path]::GetFullPath($NicxliveSourcePath)
$dll = [IO.Path]::GetFullPath($NativeDll)
$files = @('unity_backend.cs','NicxliveBehaviour.cs','NicxlivePartURP.shader','NicxliveMaskURP.shader','NicxlivePresentURP.shader')
foreach ($file in $files) {
    if (!(Test-Path -LiteralPath (Join-Path $source "unity_backend/$file"))) { throw "Missing nicxlive source: $file" }
}
if (!(Test-Path -LiteralPath $dll)) { throw "Build nijilive unity-dll first: $dll" }
$runtime = Join-Path $project 'Assets/Nicxlive/Runtime'
$editor = Join-Path $project 'Assets/Nicxlive/Editor'
$plugins = Join-Path $project 'Assets/Plugins/x86_64'
New-Item -ItemType Directory -Force $runtime,$editor,$plugins | Out-Null
# The common host imports 'nicxlive'. Install only one implementation under that name.
Copy-Item -LiteralPath $dll -Destination (Join-Path $plugins 'nicxlive.dll') -Force
foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $source "unity_backend/$file") -Destination (Join-Path $runtime $file) -Force }
foreach ($file in @('NicxliveBehaviourEditor.cs','NicxliveProjectSetup.cs')) { Copy-Item -LiteralPath (Join-Path $source "unity_backend/$file") -Destination (Join-Path $editor $file) -Force }
Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $runtime 'LICENSE-nicxlive.txt') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../LICENSE') -Destination (Join-Path $plugins 'LICENSE-nijilive.txt') -Force
'{"name":"Nicxlive.Runtime","allowUnsafeCode":true}' | Set-Content -Encoding utf8 (Join-Path $runtime 'Nicxlive.Runtime.asmdef')
'{"name":"Nicxlive.Editor","references":["Nicxlive.Runtime"],"includePlatforms":["Editor"]}' | Set-Content -Encoding utf8 (Join-Path $editor 'Nicxlive.Editor.asmdef')
Write-Host "Installed nijilive DLL with unmodified nicxlive Unity runtime and shaders: $project"
