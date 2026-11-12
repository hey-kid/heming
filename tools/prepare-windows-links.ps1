[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pluginsPath = Join-Path $projectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $pluginsPath)) { throw 'Run flutter pub get first.' }
$pluginInfo = Get-Content -LiteralPath $pluginsPath -Raw | ConvertFrom-Json
$linkDirectory = Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Path $linkDirectory -Force | Out-Null
foreach ($plugin in $pluginInfo.plugins.windows) {
    if ($plugin.name -notmatch '^[a-z][a-z0-9_]*$') { throw 'Invalid plugin name.' }
    $linkPath = Join-Path $linkDirectory $plugin.name
    if (-not (Test-Path -LiteralPath $linkPath)) {
        New-Item -ItemType Junction -Path $linkPath -Target $plugin.path | Out-Null
    }
}
Write-Output 'Windows plugin links ready. Build with --no-pub on systems without Developer Mode.'
