[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [ValidateSet('armeabi-v7a', 'arm64-v8a', 'x86_64')]
    [string[]]$ExpectedAbis = @('armeabi-v7a', 'arm64-v8a')
)

$ErrorActionPreference = 'Stop'
$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedApk)
$verified = @()
try {
    $actualAbis = @($archive.Entries | ForEach-Object {
        if ($_.FullName -match '^lib/([^/]+)/[^/]+\.so$') { $Matches[1] }
    } | Sort-Object -Unique)
    if (Compare-Object ($ExpectedAbis | Sort-Object -Unique) $actualAbis) {
        throw "Unexpected APK architectures. Expected $($ExpectedAbis -join ', '); found $($actualAbis -join ', ')."
    }
    foreach ($abi in $ExpectedAbis) {
        $expectedMachine = switch ($abi) { 'armeabi-v7a' { 40 }; 'arm64-v8a' { 183 }; 'x86_64' { 62 } }
        $expectedClass = if ($abi -eq 'armeabi-v7a') { 1 } else { 2 }
        foreach ($library in @('libflutter.so', 'libapp.so', 'libheming_audio.so', 'libsqlite3.so', 'libdartjni.so')) {
            $name = "lib/$abi/$library"
            $entry = $archive.GetEntry($name)
            if (!$entry -or $entry.Length -lt 64) { throw "Required native library missing or empty: $name" }
            $stream = $entry.Open()
            try {
                $header = New-Object byte[] 20
                $read = 0
                while ($read -lt $header.Length) {
                    $count = $stream.Read($header, $read, $header.Length - $read)
                    if ($count -eq 0) { throw "Truncated ELF header: $name" }
                    $read += $count
                }
                $machine = [int]$header[18] -bor ([int]$header[19] -shl 8)
                if ($header[0] -ne 127 -or $header[1] -ne 69 -or $header[2] -ne 76 -or $header[3] -ne 70 -or $header[4] -ne $expectedClass -or $header[5] -ne 1 -or $machine -ne $expectedMachine) {
                    throw "Invalid ELF architecture for $name."
                }
                $verified += [PSCustomObject]@{ library = $name; bytes = $entry.Length; elfMachine = $machine }
            } finally { $stream.Dispose() }
        }
    }
} finally { $archive.Dispose() }

[PSCustomObject]@{
    apk = $resolvedApk
    bytes = (Get-Item -LiteralPath $resolvedApk).Length
    sha256 = (Get-FileHash -LiteralPath $resolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    architectures = $actualAbis
    nativeLibraries = $verified
} | ConvertTo-Json -Depth 4
