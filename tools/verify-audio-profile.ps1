[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ffmpegTool = Get-Command ffmpeg -ErrorAction Stop
$ffprobeTool = Get-Command ffprobe -ErrorAction Stop
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$runName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = Join-Path $workspaceRoot ('.local\audio-profile-check\' + $runName)
$null = New-Item -ItemType Directory -Path $runDirectory -Force

function Invoke-MediaCommand {
    param([string[]]$MediaArguments)
    & $ffmpegTool.Source -hide_banner -nostdin -loglevel error @MediaArguments
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg failed with exit code $LASTEXITCODE. Fixtures remain in $runDirectory."
    }
}

function Read-AudioProfile {
    param([string]$MediaPath)
    $probeText = & $ffprobeTool.Source -v error -select_streams a:0 `
        -show_entries stream=codec_name,sample_rate,channels,bits_per_raw_sample,sample_fmt `
        -of json $MediaPath
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe could not inspect $MediaPath."
    }
    $probe = ($probeText -join "`n") | ConvertFrom-Json
    if (@($probe.streams).Count -ne 1) {
        throw "Expected one selected audio stream in $MediaPath."
    }
    return $probe.streams[0]
}

function Test-CanonicalProfile {
    param($Profile)
    return $Profile.codec_name -eq 'flac' -and `
        [int]$Profile.sample_rate -eq 48000 -and `
        [int]$Profile.channels -eq 2 -and `
        [int]$Profile.bits_per_raw_sample -eq 16
}

$sourceWav = Join-Path $runDirectory 'source 44100 mono 24bit.wav'
$sourceMp3 = Join-Path $runDirectory 'source 44100.mp3'
$sourceFlac = Join-Path $runDirectory 'source 44100.flac'
$sourceVideo = Join-Path $runDirectory 'source with video.mp4'
$canonicalFlac = Join-Path $runDirectory 'already canonical.flac'

Invoke-MediaCommand -MediaArguments @(
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=2',
    '-ac', '1', '-c:a', 'pcm_s24le', $sourceWav
)
Invoke-MediaCommand -MediaArguments @(
    '-i', $sourceWav, '-c:a', 'libmp3lame', '-b:a', '128k', $sourceMp3
)
Invoke-MediaCommand -MediaArguments @(
    '-i', $sourceWav, '-c:a', 'flac', $sourceFlac
)
Invoke-MediaCommand -MediaArguments @(
    '-f', 'lavfi', '-i', 'color=c=black:s=160x90:r=1:d=2',
    '-i', $sourceWav, '-map', '0:v:0', '-map', '1:a:0',
    '-c:v', 'mpeg4', '-c:a', 'aac', '-shortest', $sourceVideo
)
Invoke-MediaCommand -MediaArguments @(
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-ac', '2', '-c:a', 'flac', '-sample_fmt', 's16', $canonicalFlac
)

$cases = @(
    @{ Name = 'wav-mono-24bit'; Path = $sourceWav; InitiallyReady = $false },
    @{ Name = 'mp3'; Path = $sourceMp3; InitiallyReady = $false },
    @{ Name = 'flac-wrong-profile'; Path = $sourceFlac; InitiallyReady = $false },
    @{ Name = 'video-audio-track'; Path = $sourceVideo; InitiallyReady = $false },
    @{ Name = 'canonical-flac'; Path = $canonicalFlac; InitiallyReady = $true }
)

$results = foreach ($case in $cases) {
    $hashBefore = (Get-FileHash -LiteralPath $case.Path -Algorithm SHA256).Hash
    $inputProfile = Read-AudioProfile -MediaPath $case.Path
    $initialReady = Test-CanonicalProfile -Profile $inputProfile
    if ($initialReady -ne $case.InitiallyReady) {
        throw "Unexpected initial eligibility for $($case.Name)."
    }

    # This explicit developer probe invokes conversion only for its own fixtures.
    # The application must invoke the corresponding job only after a user click.
    if ($initialReady) {
        $playablePath = $case.Path
        $converted = $false
    } else {
        $playablePath = Join-Path $runDirectory ($case.Name + '.playable.flac')
        Invoke-MediaCommand -MediaArguments @(
            '-i', $case.Path, '-map', '0:a:0', '-vn', '-map_metadata', '-1',
            '-ar', '48000', '-ac', '2', '-c:a', 'flac',
            '-sample_fmt', 's16', '-compression_level', '5', $playablePath
        )
        $converted = $true
    }

    $outputProfile = Read-AudioProfile -MediaPath $playablePath
    if (-not (Test-CanonicalProfile -Profile $outputProfile)) {
        throw "Output profile mismatch for $($case.Name)."
    }

    # Force a complete decode; container metadata alone is not enough.
    Invoke-MediaCommand -MediaArguments @(
        '-xerror', '-i', $playablePath, '-map', '0:a:0', '-f', 'null', '-'
    )
    $hashAfter = (Get-FileHash -LiteralPath $case.Path -Algorithm SHA256).Hash
    if ($hashBefore -ne $hashAfter) {
        throw "The source fixture changed for $($case.Name)."
    }

    [PSCustomObject]@{
        Case = $case.Name
        InitiallyPlayable = $initialReady
        ConversionPerformed = $converted
        OutputProfile = $outputProfile
        OriginalUnchanged = $true
        CompleteDecodePassed = $true
        Source = $case.Path
        Playable = $playablePath
    }
}

$reportPath = Join-Path $runDirectory 'report.json'
$report = [PSCustomObject]@{
    Purpose = 'Synthetic fixture profile validation, not an application importer or synchronization test'
    TargetProfile = 'FLAC / 48000 Hz / 16-bit / 2 channels'
    PassedCases = @($results).Count
    Cases = @($results)
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Output "Passed $(@($results).Count) audio profile checks."
Write-Output "Report: $reportPath"
