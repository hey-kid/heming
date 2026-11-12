<#
.SYNOPSIS
Validates a completed, single-run integration driver log without contacting devices.
.EXAMPLE
.\tools\analyze-lan-validation.ps1 -LogPath .local/android-native-stability-driver.log -ExpectedSeconds 1800 -OutputPath .local/android-native-stability-summary.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogPath,
    [ValidateRange(3, 1800)][int]$ExpectedSeconds = 1800,
    [ValidateRange(0.1, 30)][double]$TimingToleranceSeconds = 5,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$resolvedLog = (Resolve-Path -LiteralPath $LogPath).Path
$failures = [Collections.Generic.List[string]]::new()
$xrunFailures = [Collections.Generic.List[string]]::new()
$records = [Collections.Generic.List[object]]::new()
$passLines = [Collections.Generic.List[int]]::new()

function Read-Number($Node, [string]$Name, [string]$Where, [switch]$Optional) {
    $property = if ($null -ne $Node) { $Node.PSObject.Properties[$Name] } else { $null }
    if ($null -eq $property -or $null -eq $property.Value) {
        if (!$Optional) { $failures.Add("$Where is missing numeric $Name.") }
        return $null
    }
    $value = $property.Value
    if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) {
        $failures.Add("$Where.$Name must be a JSON number.")
        return $null
    }
    $number = [double]$value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        $failures.Add("$Where.$Name must be finite.")
        return $null
    }
    return $number
}

function Read-Diagnostics($Node, [string]$Where, [switch]$Android) {
    $state = if ($null -ne $Node) { $Node.state } else { $null }
    if ($state -ne 'playing') { $failures.Add("$Where state must be playing; observed '$state'.") }
    $errorProperty = if ($null -ne $Node) { $Node.PSObject.Properties['error'] } else { $null }
    if ($null -eq $errorProperty) { $failures.Add("$Where is missing error status.") }
    elseif ($null -ne $errorProperty.Value -and [string]$errorProperty.Value -ne '') {
        $failures.Add("$Where reported error: $($errorProperty.Value)")
    }
    $frames = Read-Number $Node 'frames' $Where
    $buffer = Read-Number $Node 'bufferFrames' $Where
    $phase = Read-Number $Node 'phaseErrorUs' $Where
    if ($null -ne $frames -and ($frames -lt 0 -or $frames -ne [Math]::Floor($frames))) { $failures.Add("$Where.frames must be a non-negative integer.") }
    if ($null -ne $buffer -and ($buffer -lt 0 -or $buffer -gt 240000)) { $failures.Add("$Where.bufferFrames is outside the five-second buffer range: $buffer.") }
    $xruns = $null
    $rtt = $null
    if ($Android) {
        $xruns = Read-Number $Node 'outputUnderruns' $Where
        $rtt = Read-Number $Node 'rttUs' $Where
        if ($null -ne $xruns -and ($xruns -lt 0 -or $xruns -ne [Math]::Floor($xruns))) { $failures.Add("$Where Android XRun count must be a non-negative integer.") }
        if ($null -ne $xruns -and $xruns -gt 0) { $xrunFailures.Add("$Where Android XRun count is $xruns (target: 0).") }
        if ($null -ne $rtt -and $rtt -lt 0) { $failures.Add("$Where.rttUs cannot be negative.") }
    }
    return [PSCustomObject]@{ state = $state; frames = $frames; bufferFrames = $buffer; phaseErrorUs = $phase; rttUs = $rtt; androidXruns = $xruns }
}

function Metric-Range([object[]]$Values) {
    $numbers = @($Values | Where-Object { $null -ne $_ })
    if (!$numbers.Count) { return $null }
    $measure = $numbers | Measure-Object -Minimum -Maximum
    return [ordered]@{ min = $measure.Minimum; max = $measure.Maximum; last = $numbers[-1] }
}

$lineNumber = 0
# Read-only sharing lets an in-progress Tee-Object log produce a clear
# incomplete-run result rather than an unrelated sharing-violation error.
$logStream = [IO.File]::Open($resolvedLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
$logReader = [IO.StreamReader]::new($logStream, [Text.Encoding]::UTF8, $true)
try { $logText = $logReader.ReadToEnd() } finally { $logReader.Dispose() }
foreach ($rawLine in ($logText -split '[\r\n]+')) {
    $lineNumber++
    $line = [regex]::Replace($rawLine, '\x1b\[[0-?]*[ -/]*[@-~]', '')
    if ($line -match '(?:^|\s)All tests passed\.\s*$') { $passLines.Add($lineNumber) }
    if ($line -notmatch '\b(LOCAL_RESULT|LAN_SAMPLE|LAN_RESULT|LAN_REVERSE_RESULT)\s+(.*)$') { continue }
    $kind = $Matches[1]
    $json = $Matches[2]
    try {
        $data = $json | ConvertFrom-Json -ErrorAction Stop
        if (!$json.TrimStart().StartsWith('{') -or !$json.TrimEnd().EndsWith('}')) { throw 'Expected a JSON object.' }
        $records.Add([PSCustomObject]@{ kind = $kind; line = $lineNumber; data = $data })
    } catch { $failures.Add("Malformed $kind JSON at line ${lineNumber}: $($_.Exception.Message)") }
}

foreach ($kind in @('LOCAL_RESULT', 'LAN_RESULT', 'LAN_REVERSE_RESULT')) {
    $count = @($records | Where-Object kind -eq $kind).Count
    if ($count -ne 1) { $failures.Add("Expected exactly one $kind record; found $count. Use one complete driver run per log.") }
}
if ($passLines.Count -ne 1) { $failures.Add("Expected one final 'All tests passed.' marker; found $($passLines.Count). The log may be incomplete or contain multiple runs.") }
$localRecord = $records | Where-Object kind -eq 'LOCAL_RESULT' | Select-Object -First 1
$endRecord = $records | Where-Object kind -eq 'LAN_RESULT' | Select-Object -First 1
$reverseRecord = $records | Where-Object kind -eq 'LAN_REVERSE_RESULT' | Select-Object -First 1
$periodic = @($records | Where-Object kind -eq 'LAN_SAMPLE')
if ($ExpectedSeconds -ge 30 -and $periodic.Count -lt [Math]::Min(2, [Math]::Floor($ExpectedSeconds / 30))) {
    $failures.Add('Missing periodic LAN_SAMPLE observations for the requested duration.')
}
if ($localRecord -and $endRecord -and $reverseRecord) {
    if ($localRecord.line -ge $endRecord.line -or $endRecord.line -ge $reverseRecord.line) { $failures.Add('Result records are out of order.') }
    if ($passLines.Count -eq 1 -and $passLines[0] -le $reverseRecord.line) { $failures.Add('The success marker precedes the final reverse-stream result.') }
}

$local = $null
if ($localRecord) {
    $local = Read-Diagnostics $localRecord.data 'LOCAL_RESULT' -Android
    if ($null -ne $local.frames -and $local.frames -le 10000) { $failures.Add('LOCAL_RESULT does not show the expected local playback progress.') }
}
$samples = [Collections.Generic.List[object]]::new()
$previous = $null
$streamRecords = @($periodic)
if ($endRecord) { $streamRecords += $endRecord }
foreach ($record in $streamRecords) {
    $where = "$($record.kind) line $($record.line)"
    if ($record.kind -eq 'LAN_SAMPLE' -and (($localRecord -and $record.line -lt $localRecord.line) -or ($endRecord -and $record.line -gt $endRecord.line))) { $failures.Add("$where is outside the forward test.") }
    $elapsed = Read-Number $record.data 'elapsedSeconds' $where
    if ($null -ne $elapsed -and $elapsed -lt 0) { $failures.Add("$where has a negative elapsed time.") }
    $sample = [PSCustomObject]@{ kind = $record.kind; elapsedSeconds = $elapsed; android = (Read-Diagnostics $record.data.android "$where android" -Android); windows = (Read-Diagnostics $record.data.windows "$where windows") }
    if ($previous) {
        $sameEndSecond = $record.kind -eq 'LAN_RESULT' -and $elapsed -eq $previous.elapsedSeconds
        if ($elapsed -lt $previous.elapsedSeconds -or (!$sameEndSecond -and $elapsed -eq $previous.elapsedSeconds)) { $failures.Add("$where elapsed time does not advance.") }
        foreach ($side in @('android', 'windows')) {
            $nowFrames = $sample.$side.frames
            $beforeFrames = $previous.$side.frames
            if ($null -ne $nowFrames -and $null -ne $beforeFrames -and ($nowFrames -lt $beforeFrames -or (!$sameEndSecond -and $nowFrames -eq $beforeFrames))) {
                $failures.Add("$where $side frames do not strictly advance ($beforeFrames -> $nowFrames). Only an endpoint in the same elapsed second may repeat a frame position.")
            }
        }
        if ($sample.android.androidXruns -lt $previous.android.androidXruns) { $failures.Add("$where Android XRun count decreased within the same forward stream.") }
    }
    $samples.Add($sample)
    $previous = $sample
}

$end = $samples | Where-Object kind -eq 'LAN_RESULT' | Select-Object -First 1
$expectedMediaSeconds = $ExpectedSeconds - 1.5
if ($end) {
    if ($end.elapsedSeconds -lt $ExpectedSeconds) { $failures.Add("Completed elapsed time $($end.elapsedSeconds)s is shorter than requested ${ExpectedSeconds}s.") }
    foreach ($side in @('android', 'windows')) {
        if ($null -ne $end.$side.frames) {
            $mediaSeconds = $end.$side.frames / 48000.0
            if ([Math]::Abs($mediaSeconds - $expectedMediaSeconds) -gt $TimingToleranceSeconds) { $failures.Add("$side endpoint media time ${mediaSeconds}s is not within ${TimingToleranceSeconds}s of expected ${expectedMediaSeconds}s.") }
        }
    }
}
$reverse = $null
if ($reverseRecord) {
    $reverse = [ordered]@{ android = (Read-Diagnostics $reverseRecord.data.android 'LAN_REVERSE_RESULT android' -Android); windows = (Read-Diagnostics $reverseRecord.data.windows 'LAN_REVERSE_RESULT windows') }
    foreach ($side in @('android', 'windows')) {
        if ($null -ne $reverse[$side].frames -and $reverse[$side].frames -le 40000) { $failures.Add("Reverse $side result does not show expected playback progress.") }
    }
}

$forward = [ordered]@{ periodicSampleCount = $periodic.Count; totalObservationCount = $samples.Count; elapsedSeconds = $(if ($end) { $end.elapsedSeconds } else { $null }); expectedSeconds = $ExpectedSeconds; mediaSampleRate = 48000; expectedEndpointMediaSeconds = $expectedMediaSeconds; endpointToleranceSeconds = $TimingToleranceSeconds }
foreach ($side in @('android', 'windows')) {
    $sideSamples = @($samples | ForEach-Object { $_.$side })
    $forward[$side] = [ordered]@{
        endpointFrames = $(if ($end) { $end.$side.frames } else { $null })
        endpointMediaSeconds = $(if ($end -and $null -ne $end.$side.frames) { $end.$side.frames / 48000.0 } else { $null })
        bufferFrames = Metric-Range @($sideSamples | ForEach-Object bufferFrames)
        modeledPhaseErrorUs = Metric-Range @($sideSamples | ForEach-Object phaseErrorUs)
    }
}
$forward.android['androidXruns'] = Metric-Range @($samples | ForEach-Object { $_.android.androidXruns })
if ($samples.Count -gt 0 -and $null -ne $samples[0].android.androidXruns -and $end -and $null -ne $end.android.androidXruns) {
    $forward.android['androidXrunDelta'] = $end.android.androidXruns - $samples[0].android.androidXruns
}
$forward.android['rttUs'] = Metric-Range @($samples | ForEach-Object { $_.android.rttUs })
$summary = [ordered]@{
    log = $resolvedLog
    passed = ($failures.Count -eq 0 -and $xrunFailures.Count -eq 0)
    softwarePlaybackChecksPassed = ($failures.Count -eq 0)
    androidNoXrunChecksPassed = ($xrunFailures.Count -eq 0 -and $failures.Count -eq 0)
    successMarkerFound = ($passLines.Count -eq 1)
    local = $local
    forward = $forward
    reverse = $reverse
    unavailableDiagnostics = @('Android hardwareRatePpm: estimator not implemented; zero is not measured zero drift.', 'Windows outputUnderruns: counter not implemented; zero is a placeholder.')
    measurementBoundary = 'Muted software stability validation only. Phase ranges are model estimates. HTTP observations are sequential; frame differences are not acoustic speaker offsets.'
    validationFailures = @($failures)
    androidXrunFailures = @($xrunFailures)
}
$jsonSummary = $summary | ConvertTo-Json -Depth 8
if ($OutputPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $jsonSummary, [Text.UTF8Encoding]::new($false)) }
Write-Output $jsonSummary
if (!$summary.passed) {
    throw "LAN validation did not pass: $($failures.Count) completeness/playback issue(s), $($xrunFailures.Count) Android no-XRun issue(s). See the JSON failure lists; XRun findings do not by themselves mean playback stopped."
}
