Add-Type -AssemblyName System.Drawing
$source = Join-Path $PSScriptRoot '..\..\macos\App\CodexRemote.iconset\icon_256x256.png'
$output = Join-Path $PSScriptRoot '..\src\CodexRemote.WindowsApp\Assets\CodexRemote.ico'
$bitmap = [System.Drawing.Bitmap]::FromFile($source)
$icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
$stream = [System.IO.File]::Create($output)
try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose(); $bitmap.Dispose() }
