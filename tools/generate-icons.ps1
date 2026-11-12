[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path -Parent $PSScriptRoot
function Write-HemingIcon([int]$size, [string]$destination) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::FromArgb(37, 102, 76))
    $brush = [Drawing.SolidBrush]::new([Drawing.Color]::White)
    $heights = @(0.23, 0.45, 0.65, 0.36, 0.16)
    for ($i = 0; $i -lt $heights.Count; $i++) {
        $height = [single]($size * $heights[$i])
        $graphics.FillRectangle($brush, [single]($size * (0.23 + $i * 0.115)), [single](($size - $height) / 2), [single]($size * 0.065), $height)
    }
    $bitmap.Save($destination, [Drawing.Imaging.ImageFormat]::Png)
    $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
foreach ($entry in $densities.GetEnumerator()) {
    Write-HemingIcon $entry.Value (Join-Path $projectRoot "android\app\src\main\res\mipmap-$($entry.Key)\ic_launcher.png")
}
$iconPng = Join-Path $projectRoot '.local\heming-icon.png'
Write-HemingIcon 256 $iconPng
$png = [IO.File]::ReadAllBytes($iconPng)
$stream = [IO.File]::Create((Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'))
$writer = [IO.BinaryWriter]::new($stream)
$writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]1)
$writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0)
$writer.Write([UInt16]1); $writer.Write([UInt16]32); $writer.Write([UInt32]$png.Length); $writer.Write([UInt32]22)
$writer.Write($png); $writer.Dispose(); $stream.Dispose()
Write-Output 'Generated Heming Android and Windows icons.'
