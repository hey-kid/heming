[CmdletBinding()]
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$previousLocation = Get-Location
try {
    Set-Location -LiteralPath $projectRoot
    if (!$SkipBuild) {
        & (Join-Path $PSScriptRoot 'prepare-windows-links.ps1')
        & flutter --no-version-check --suppress-analytics build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    }
    $bundle = Join-Path $projectRoot 'build\windows\x64\runner\Release'
    if (!(Test-Path -LiteralPath (Join-Path $bundle 'heming.exe'))) { throw 'No Windows release build exists.' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsRoot = (& $vswhere -latest -products '*' -property installationPath | Select-Object -First 1).Trim()
    $runtime = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.' } | Sort-Object Name -Descending | Select-Object -First 1 |
        ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName 'x64') -Directory | Where-Object { $_.Name -like 'Microsoft.VC*.CRT' } } |
        Select-Object -First 1
    if (!$runtime) { throw 'Visual C++ redistributable runtime not found.' }
    Get-ChildItem -LiteralPath $runtime.FullName -Filter '*.dll' | Copy-Item -Destination $bundle
    Copy-Item -LiteralPath (Join-Path $projectRoot 'packages\heming_audio\THIRD_PARTY_NOTICES.md') -Destination $bundle
    $dist = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $zip = Join-Path $dist 'heming-windows-x64.zip'
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -Force
    Get-FileHash -LiteralPath $zip -Algorithm SHA256 | Format-List
    Write-Output "Windows package: $zip"
} finally { Set-Location -LiteralPath $previousLocation.Path }
