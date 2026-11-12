[CmdletBinding()]
param(
    [string]$AndroidSdk = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$BuildToolsVersion = '36.0.0',
    [int]$CompileSdk = 36,
    [string]$DebugKeystore = (Join-Path $env:USERPROFILE '.android\debug.keystore'),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (!$OutputPath) { $OutputPath = Join-Path $workspace '.local\focus-probe.apk' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (!$JavaHome) {
    foreach ($candidate in @(
        'D:\Program Files\Android\Android Studio\jbr',
        (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr')
    )) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\javac.exe')) {
            $JavaHome = $candidate
            break
        }
    }
}
if (!$JavaHome) { throw 'Pass -JavaHome pointing to a JDK that includes javac.' }
$buildTools = Join-Path $AndroidSdk ('build-tools\' + $BuildToolsVersion)
$platformJar = Join-Path $AndroidSdk ('platforms\android-' + $CompileSdk + '\android.jar')
$javac = Join-Path $JavaHome 'bin\javac.exe'
$jar = Join-Path $JavaHome 'bin\jar.exe'
$aapt = Join-Path $buildTools 'aapt2.exe'
$d8 = Join-Path $buildTools 'd8.bat'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$signer = Join-Path $buildTools 'apksigner.bat'
foreach ($required in @($platformJar, $javac, $jar, $aapt, $d8, $zipalign, $signer, $DebugKeystore)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing tool/input: $required" }
}
# Each build uses a fresh task-owned directory; there are no recursive deletes
# and no changes to the product Gradle project or installed applications.
$buildDirectory = Join-Path $workspace ('.local\focus-probe-build-' + [guid]::NewGuid().ToString('N'))
$classes = Join-Path $buildDirectory 'classes'
$dex = Join-Path $buildDirectory 'dex'
$null = New-Item -ItemType Directory -Path $classes, $dex, (Split-Path -Parent $OutputPath) -Force
$classJar = Join-Path $buildDirectory 'classes.jar'
$unsigned = Join-Path $buildDirectory 'unsigned.apk'
$aligned = Join-Path $buildDirectory 'aligned.apk'
$previousJavaHome = $env:JAVA_HOME
function Assert-ToolSuccess([string]$step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed with exit code $LASTEXITCODE" }
}
try {
    $env:JAVA_HOME = $JavaHome
    & $javac --release 8 -encoding UTF-8 -classpath $platformJar -d $classes (Join-Path $PSScriptRoot 'MainActivity.java')
    Assert-ToolSuccess 'javac'
    & $jar --create --file $classJar -C $classes .
    Assert-ToolSuccess 'jar'
    & $d8 --release --min-api 26 --lib $platformJar --output $dex $classJar
    Assert-ToolSuccess 'd8'
    & $aapt link -o $unsigned --manifest (Join-Path $PSScriptRoot 'AndroidManifest.xml') -I $platformJar --version-code 1 --version-name 1.0
    Assert-ToolSuccess 'aapt2'
    $archive = [IO.Compression.ZipFile]::Open($unsigned, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, (Join-Path $dex 'classes.dex'), 'classes.dex', [IO.Compression.CompressionLevel]::Optimal)
    } finally { $archive.Dispose() }
    & $zipalign -f 4 $unsigned $aligned
    Assert-ToolSuccess 'zipalign'
    & $signer sign --ks $DebugKeystore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out $OutputPath $aligned
    Assert-ToolSuccess 'apksigner sign'
    & $signer verify --verbose $OutputPath
    Assert-ToolSuccess 'apksigner verify'
    & $aapt dump badging $OutputPath
    Assert-ToolSuccess 'aapt2 dump'
    [pscustomobject]@{
        Apk = $OutputPath
        Package = 'app.heming.focusprobe'
        Bytes = (Get-Item -LiteralPath $OutputPath).Length
        SHA256 = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json
} finally {
    $env:JAVA_HOME = $previousJavaHome
}
