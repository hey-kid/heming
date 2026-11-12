[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Mode = 'debug',
    [ValidateSet('android-arm', 'android-arm64', 'android-x64')][string[]]$TargetPlatform = @('android-arm', 'android-arm64'),
    [string]$EntryPoint = 'lib/main.dart',
    [string[]]$DartDefine = @(),
    [string]$ProxyUrl,
    [string]$InstallTo
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$socketDirectory = Join-Path $workspaceRoot '.local\java-uds'
$null = New-Item -ItemType Directory -Path $socketDirectory -Force
$previousJavaOptions = $env:JAVA_TOOL_OPTIONS
$previousLocation = Get-Location
$registrantPath = Join-Path $workspaceRoot 'android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java'
$registrantBytes = $null
try {
    # Windows packaged hosts may redirect the default temp path used by Java
    # AF_UNIX sockets. An explicit workspace directory keeps both pipe ends
    # on the same path without changing machine-wide Java or network settings.
    $options = @($previousJavaOptions, ('"-Djdk.net.unixdomain.tmpdir=' + $socketDirectory + '"'), '-Djava.net.preferIPv4Stack=true')
    if ($ProxyUrl) {
        $proxy = [Uri]$ProxyUrl
        if ($proxy.Scheme -ne 'http' -or !$proxy.Host) { throw 'ProxyUrl must be an HTTP proxy URL, such as http://127.0.0.1:7897.' }
        $options += @(
            "-Dhttp.proxyHost=$($proxy.Host)", "-Dhttp.proxyPort=$($proxy.Port)",
            "-Dhttps.proxyHost=$($proxy.Host)", "-Dhttps.proxyPort=$($proxy.Port)",
            '-Dhttp.nonProxyHosts=localhost|127.*|[::1]'
        )
    }
    $env:JAVA_TOOL_OPTIONS = ($options | Where-Object { $_ }) -join ' '
    Set-Location -LiteralPath $workspaceRoot
    if (!(Test-Path -LiteralPath $EntryPoint -PathType Leaf)) { throw "Entry point does not exist: $EntryPoint" }
    if ($Mode -eq 'release' -and (Test-Path -LiteralPath $registrantPath)) {
        # Flutter 3.44 excludes native dev plugins from release dependencies,
        # but --no-pub can retain their generated Java registration. Keep the
        # integration test SDK out of release and restore debug registration.
        $originalRegistrant = [IO.File]::ReadAllBytes($registrantPath)
        $registrantText = [Text.Encoding]::UTF8.GetString($originalRegistrant)
        if ($registrantText.Contains('dev.flutter.plugins.integration_test.IntegrationTestPlugin')) {
            $testRegistration = '(?m)^    try \{\r?\n      flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\r?\n    \} catch \(Exception e\) \{\r?\n      Log\.e\(TAG, "Error registering plugin integration_test,[^\r\n]*\r?\n    \}\r?\n'
            if ([regex]::Matches($registrantText, $testRegistration).Count -ne 1) {
                throw 'Flutter generated registration changed; update the release filtering rule before building.'
            }
            $registrantBytes = $originalRegistrant
            [IO.File]::WriteAllText($registrantPath, [regex]::Replace($registrantText, $testRegistration, ''), [Text.UTF8Encoding]::new($false))
        }
    }
    $buildArguments = @('--no-version-check', '--suppress-analytics', 'build', 'apk', "--$Mode", '--target-platform', ($TargetPlatform -join ','), '--target', $EntryPoint, '--no-pub')
    foreach ($definition in $DartDefine) {
        if ($definition -notmatch '^[^=\s]+=') { throw "DartDefine must use NAME=value syntax: $definition" }
        $buildArguments += "--dart-define=$definition"
    }
    & flutter @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "Android build failed with exit code $LASTEXITCODE." }
    $apkPath = Join-Path $workspaceRoot "build\app\outputs\flutter-apk\app-$Mode.apk"
    Write-Output "APK: $apkPath"
    if ($InstallTo) {
        $adbPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
        if (!(Test-Path -LiteralPath $adbPath)) { $adbPath = (Get-Command adb -ErrorAction Stop).Source }
        & $adbPath -s $InstallTo install -r $apkPath
        if ($LASTEXITCODE -ne 0) { throw "APK installation failed with exit code $LASTEXITCODE." }
    }
} finally {
    if ($null -ne $registrantBytes) { [IO.File]::WriteAllBytes($registrantPath, $registrantBytes) }
    $env:JAVA_TOOL_OPTIONS = $previousJavaOptions
    Set-Location -LiteralPath $previousLocation.Path
}
