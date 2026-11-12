<#
.SYNOPSIS
Runs the integration driver against an already installed debug test APK.
.DESCRIPTION
Never builds, installs, or uninstalls an APK. Install the debug test APK through
the device's normal installer first. StartApp restarts that installed app paused
at main, discovers its new VM service URL from logcat, then lets the driver resume
it. Alternatively supply the exact device-side URL observed in Android logcat.
VM service authentication remains enabled. The script owns only its newly
allocated adb port forward and removes that forward when the driver exits.
.EXAMPLE
.\tools\test-android-existing.ps1 -Serial '<DEVICE_SERIAL>' -StartApp
.EXAMPLE
.\tools\test-android-existing.ps1 -Serial '<DEVICE_SERIAL>' -VmServiceUrl 'http://127.0.0.1:<PORT>/<OBSERVED_TOKEN>/'
#>
[CmdletBinding(DefaultParameterSetName = 'ObservedUrl')]
param(
    [Parameter(Mandatory)][string]$Serial,
    [Parameter(Mandatory, ParameterSetName = 'ObservedUrl')][string]$VmServiceUrl,
    [Parameter(Mandatory, ParameterSetName = 'Launch')][switch]$StartApp,
    [ValidatePattern('^[A-Za-z0-9_.]+$')][string]$PackageName = 'app.heming.heming',
    [ValidatePattern('^[A-Za-z0-9_.$]+$')][string]$ActivityName = 'app.heming.heming.MainActivity',
    [ValidateRange(30, 86400)][int]$TimeoutSeconds = 2400,
    [ValidateRange(5, 120)][int]$DiscoveryTimeoutSeconds = 30,
    [string]$Driver = 'test_driver/device_smoke_driver.dart',
    [string]$AdbPath
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent $PSScriptRoot
if (!$AdbPath) {
    $AdbPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (!(Test-Path -LiteralPath $AdbPath)) { $AdbPath = (Get-Command adb -ErrorAction Stop).Source }
}
$previousLocation = Get-Location
$previousTimeout = $env:HEMING_TEST_TIMEOUT_SECONDS
$forwardedPort = $null

function Invoke-AndroidCommand {
    param([string[]]$Arguments)
    $commandOutput = & $adbPath -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb $($Arguments -join ' ') failed ($LASTEXITCODE): $($commandOutput -join [Environment]::NewLine)"
    }
    return ($commandOutput -join [Environment]::NewLine).Trim()
}

try {
    Set-Location -LiteralPath $workspaceRoot
    if (!(Test-Path -LiteralPath $Driver -PathType Leaf)) { throw "Driver file does not exist: $Driver" }
    if ((Invoke-AndroidCommand -Arguments @('get-state')) -ne 'device') { throw "Device $Serial is not online and authorized." }
    $installedPath = Invoke-AndroidCommand -Arguments @('shell', 'pm', 'path', $PackageName)
    if ($installedPath -notmatch '(?m)^package:') {
        throw "$PackageName is not installed. Install the intended debug test APK through the device installer first."
    }

    if ($PSCmdlet.ParameterSetName -eq 'Launch') {
        $packageDetails = Invoke-AndroidCommand -Arguments @('shell', 'dumpsys', 'package', $PackageName)
        if ($packageDetails -notmatch '\bDEBUGGABLE\b') {
            throw "$PackageName is not debuggable. Install a debug APK built with integration_test/device_smoke_test.dart before starting this script."
        }
        $null = Invoke-AndroidCommand -Arguments @('shell', 'am', 'force-stop', $PackageName)
        $deviceEpoch = Invoke-AndroidCommand -Arguments @('shell', 'date', '+%s')
        if ($deviceEpoch -notmatch '^\d+$') { throw "Could not read device time for fresh log discovery: $deviceEpoch" }
        $launchOutput = Invoke-AndroidCommand -Arguments @('shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', '-n', "$PackageName/$ActivityName", '--ez', 'start-paused', 'true', '--ez', 'enable-checked-mode', 'true', '--ez', 'verify-entry-points', 'true')
        if ($launchOutput -match '(?im)^Error:') { throw "Android could not launch the installed test app: $launchOutput" }

        $watch = [Diagnostics.Stopwatch]::StartNew()
        $appProcessId = $null
        $lastLogs = ''
        while ($watch.Elapsed.TotalSeconds -lt $DiscoveryTimeoutSeconds) {
            if (!$appProcessId) {
                $processOutput = & $adbPath -s $Serial shell pidof $PackageName 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $appProcessId = (($processOutput -join ' ').Trim() -split '\s+')[0]
                    if ($appProcessId -notmatch '^\d+$') { $appProcessId = $null }
                }
            }
            if ($appProcessId) {
                # Both the new PID and launch timestamp exclude stale URLs from
                # previous runs without clearing the user's Android log buffer.
                $lastLogs = Invoke-AndroidCommand -Arguments @('logcat', '-d', '-v', 'raw', "--pid=$appProcessId", '-T', "$deviceEpoch.000")
                $urlMatches = [regex]::Matches($lastLogs, '(?:Dart VM service|VM Service) is listening on\s+(https?://[^\s]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($urlMatches.Count -gt 0) {
                    $VmServiceUrl = $urlMatches[$urlMatches.Count - 1].Groups[1].Value.TrimEnd('.')
                    break
                }
            }
            Start-Sleep -Milliseconds 250
        }
        if (!$VmServiceUrl) {
            $logTail = (($lastLogs -split '\r?\n') | Select-Object -Last 35) -join [Environment]::NewLine
            throw "No fresh Dart VM service URL appeared within $DiscoveryTimeoutSeconds seconds. Confirm the installed APK is the debug integration-test target and the phone is unlocked. Recent app logs:`n$logTail"
        }
    }

    $deviceUri = $null
    if (![Uri]::TryCreate($VmServiceUrl, [UriKind]::Absolute, [ref]$deviceUri) -or
        $deviceUri.Scheme -notin @('http', 'ws') -or
        $deviceUri.Host -notin @('localhost', '127.0.0.1', '[::1]', '::1') -or
        $deviceUri.Port -lt 1 -or $deviceUri.UserInfo) {
        throw 'VmServiceUrl must be the exact loopback HTTP/WS URL printed by the Android Dart VM service, including its authentication path. Do not supply an already forwarded host URL.'
    }
    $portText = Invoke-AndroidCommand -Arguments @('forward', 'tcp:0', "tcp:$($deviceUri.Port)")
    if ($portText -notmatch '^\d+$') { throw "adb did not return an allocated forwarding port: $portText" }
    $forwardedPort = [int]$portText
    $hostUri = [UriBuilder]::new($deviceUri)
    $hostUri.Host = '127.0.0.1'
    $hostUri.Port = $forwardedPort
    $env:HEMING_TEST_TIMEOUT_SECONDS = $TimeoutSeconds.ToString()
    Write-Output "Attached driver to device $Serial (device port $($deviceUri.Port), local port $forwardedPort). Timeout: $TimeoutSeconds seconds."
    & flutter --no-version-check --suppress-analytics drive --no-pub --no-dds --device-id $Serial --driver $Driver --use-existing-app $hostUri.Uri.AbsoluteUri --timeout $TimeoutSeconds --keep-app-running
    if ($LASTEXITCODE -ne 0) { throw "Integration driver failed with exit code $LASTEXITCODE. See the assertion/connection details above; no installation or uninstall was attempted." }
} finally {
    if ($null -ne $forwardedPort) {
        & $adbPath -s $Serial forward --remove "tcp:$forwardedPort" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not remove adb forward tcp:$forwardedPort; the device may have disconnected." }
    }
    $env:HEMING_TEST_TIMEOUT_SECONDS = $previousTimeout
    Set-Location -LiteralPath $previousLocation.Path
}
