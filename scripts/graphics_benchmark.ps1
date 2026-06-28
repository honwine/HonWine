<#
.SYNOPSIS
Run and summarize WineHua graphics smoke benchmarks on a HarmonyOS target.

.DESCRIPTION
Starts the app with benchmark parameters, waits for completion, collects hilog,
and parses the graphics smoke control flow and GraphicsStats lines into JSON.
#>
[CmdletBinding()]
param(
    [string]$Target = '127.0.0.1:5555',
    [string]$HdcPath = '',
    [ValidateSet('graphics-smoke', 'graphics-direct', 'graphics-explorer')]
    [string]$Mode = 'graphics-smoke',
    [ValidateSet('auto', 'cpu_shm_upload', 'gl_compositor_direct')]
    [string]$Presenter = 'auto',
    [int]$Seconds = 4,
    [int]$Iterations = 1,
    [int]$WaitSeconds = 90,
    [int]$TailLines = 70000,
    [switch]$NoForceStop,
    [string]$OutDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BundleName = 'app.hackeris.winehua'
$AbilityName = 'EntryAbility'

function Resolve-HdcPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path $RequestedPath)) {
            throw "HDC path does not exist: $RequestedPath"
        }
        return (Resolve-Path $RequestedPath).Path
    }

    $candidates = @(
        (Join-Path $RepoRoot 'out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe'),
        $env:HDC_PATH,
        'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
        'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    $cmd = Get-Command hdc.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Unable to locate hdc.exe. Pass -HdcPath or set HDC_PATH.'
}

function Invoke-Hdc {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    $output = & $script:Hdc -t $Target @Args
    if ($LASTEXITCODE -ne 0) {
        throw "hdc failed ($($Args -join ' ')): $output"
    }
    return $output
}

function Convert-StatsValue {
    param([string]$Value)

    if ($Value -eq 'true') { return $true }
    if ($Value -eq 'false') { return $false }
    $number = 0.0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        if ($Value -notmatch '\.' -and $number -ge [int64]::MinValue -and $number -le [int64]::MaxValue) {
            return [int64]$number
        }
        return $number
    }
    return $Value
}

function Parse-StatsLine {
    param([string]$Line)

    $stats = [ordered]@{}
    $payload = ($Line -replace '^.*\[GraphicsStats\]\s*', '')
    foreach ($part in ($payload -split '\s+')) {
        if ($part -match '^([^=]+)=(.*)$') {
            $stats[$Matches[1]] = Convert-StatsValue $Matches[2]
        }
    }
    return $stats
}

function Get-StatNumber {
    param(
        [object]$Stats,
        [string]$Key
    )

    if ($null -eq $Stats) { return 0.0 }
    if (-not $Stats.Contains($Key)) { return 0.0 }
    $value = $Stats[$Key]
    if ($null -eq $value) { return 0.0 }
    return [double]$value
}

function Get-StatsActivityScore {
    param([object]$Stats)

    if ($null -eq $Stats) { return 0.0 }
    return (Get-StatNumber $Stats 'partial_upload') * 1000000.0 +
        (Get-StatNumber $Stats 'full_upload') * 100000.0 +
        (Get-StatNumber $Stats 'damage_rects') * 1000.0 +
        (Get-StatNumber $Stats 'gl_upload_mb') * 100.0 +
        (Get-StatNumber $Stats 'avg_present_ms') +
        (Get-StatNumber $Stats 'avg_upload_ms')
}

if (-not $OutDir) {
    $OutDir = Join-Path $RepoRoot 'out\graphics-benchmarks'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:Hdc = Resolve-HdcPath $HdcPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rawLogPath = Join-Path $OutDir "graphics-benchmark-$timestamp.hilog.txt"
$jsonPath = Join-Path $OutDir "graphics-benchmark-$timestamp.json"

Write-Host "[graphics-bench] hdc=$script:Hdc target=$Target mode=$Mode presenter=$Presenter seconds=$Seconds iterations=$Iterations"

& $script:Hdc tconn $Target | Out-Null
Invoke-Hdc @('shell', 'hilog -G 16M -t app') | Out-Null
if (-not $NoForceStop) {
    Invoke-Hdc @('shell', "aa force-stop $BundleName") | Out-Null
    Start-Sleep -Seconds 1
}
Invoke-Hdc @('shell', 'hilog -r') | Out-Null
Invoke-Hdc @('shell', "aa start -b $BundleName -a $AbilityName --ps benchmark $Mode --ps presenter $Presenter --pi seconds $Seconds --pi iterations $Iterations") | Out-Null
Start-Sleep -Seconds $WaitSeconds

$raw = Invoke-Hdc @('shell', "hilog -x -t app")
$raw | Set-Content -LiteralPath $rawLogPath -Encoding UTF8

$lines = $raw -split "`r?`n"
$steps = [ordered]@{}
$activeStep = ''
$currentPidToStep = @{}
$allStats = New-Object System.Collections.Generic.List[object]
$ignoredStats = 0
$benchmarkComplete = $false

foreach ($line in $lines) {
    if ($line -notmatch 'A00000') { continue }

    if ($line -match '\[Bench\] starting step=([^\s]+)(?: presenter=([^\s]+))? exe=([^\s]+) args=(.*)$') {
        $activeStep = $Matches[1]
        $stepPresenter = if ($Matches.ContainsKey(2) -and $Matches[2]) { $Matches[2] } else { $Presenter }
        $benchmarkComplete = $false
        if (-not $steps.Contains($activeStep)) {
            $steps[$activeStep] = [ordered]@{
                started = $true
                presenter = $stepPresenter
                exe = $Matches[3]
                args = $Matches[4]
                pid = $null
                timedOut = $false
                sampled = $false
                exited = $false
                finished = $false
                completed = $false
                xdgAppIds = @()
                warnings = @()
                stats = @()
            }
        }
        continue
    }

    if ($line -match '\[Bench\] running step=([^\s]+) pid=([0-9-]+)') {
        $step = $Matches[1]
        $processId = [int]$Matches[2]
        if (-not $steps.Contains($step)) {
            $steps[$step] = [ordered]@{
                started = $false
                presenter = $Presenter
                exe = $null
                args = $null
                pid = $processId
                timedOut = $false
                sampled = $false
                exited = $false
                finished = $false
                completed = $false
                xdgAppIds = @()
                warnings = @()
                stats = @()
            }
        }
        $steps[$step].pid = $processId
        $currentPidToStep[[string]$processId] = $step
        $activeStep = $step
        continue
    }

    if ($line -match '\[Bench\] finished step=([^\s]+) pid=([0-9-]+)') {
        $step = $Matches[1]
        if ($steps.Contains($step)) {
            $steps[$step].finished = $true
            $steps[$step].exited = $true
            if (-not $steps[$step].pid) {
                $steps[$step].pid = [int]$Matches[2]
            }
        }
        if ($activeStep -eq $step) {
            $activeStep = ''
        }
        continue
    }

    if ($line -match '\[Bench\] timeout step=([^\s]+) pid=([0-9-]+)') {
        $step = $Matches[1]
        if (-not $steps.Contains($step)) {
            $steps[$step] = [ordered]@{
                started = $false
                presenter = $Presenter
                exe = $null
                args = $null
                pid = [int]$Matches[2]
                timedOut = $false
                sampled = $false
                exited = $false
                finished = $false
                completed = $false
                xdgAppIds = @()
                warnings = @()
                stats = @()
            }
        }
        $steps[$step].timedOut = $true
        if ($activeStep -eq $step) {
            $activeStep = ''
        }
        continue
    }

    if ($line -match '\[Bench\] sampled step=([^\s]+) pid=([0-9-]+)') {
        $step = $Matches[1]
        if (-not $steps.Contains($step)) {
            $steps[$step] = [ordered]@{
                started = $false
                presenter = $Presenter
                exe = $null
                args = $null
                pid = [int]$Matches[2]
                timedOut = $false
                sampled = $false
                exited = $false
                finished = $false
                completed = $false
                xdgAppIds = @()
                warnings = @()
                stats = @()
            }
        }
        $steps[$step].sampled = $true
        if ($activeStep -eq $step) {
            $activeStep = ''
        }
        continue
    }

    if ($line -match '\[Bench\] complete mode=') {
        foreach ($key in @($steps.Keys)) {
            $steps[$key].completed = $true
        }
        $activeStep = ''
        $benchmarkComplete = $true
        continue
    }

    if ($line -match 'state:\s+([0-9-]+):exited') {
        $processId = $Matches[1]
        if ($currentPidToStep.ContainsKey($processId)) {
            $steps[$currentPidToStep[$processId]].exited = $true
        }
        continue
    }

    if ($line -match '\[XDG\] app_id=([^\s]+)') {
        if ($activeStep -and $steps.Contains($activeStep)) {
            $ids = @($steps[$activeStep].xdgAppIds)
            $ids += $Matches[1]
            $steps[$activeStep].xdgAppIds = $ids
        }
        continue
    }

    if ($line -match 'winehua_graphics_smoke: GL vendor=') {
        if ($activeStep -and $steps.Contains($activeStep)) {
            $warnings = @($steps[$activeStep].warnings)
            $warnings += $line
            $steps[$activeStep].warnings = $warnings
        }
        continue
    }

    if ($line -match '\[GraphicsStats\]') {
        if ($benchmarkComplete -or -not $activeStep -or -not $steps.Contains($activeStep)) {
            $ignoredStats++
            continue
        }
        $stats = Parse-StatsLine $line
        $stats['step'] = if ($activeStep) { $activeStep } else { 'unknown' }
        if ($line -match '^\S+\s+\S+\s+\d+\s+([0-9]+)\s+') {
            $stats['rendererThread'] = [int]$Matches[1]
        }
        $allStats.Add($stats) | Out-Null
        $statsList = @($steps[$activeStep].stats)
        $statsList += $stats
        $steps[$activeStep].stats = $statsList
        continue
    }
}

$summarySteps = [ordered]@{}
foreach ($key in $steps.Keys) {
    $step = $steps[$key]
    $latest = $null
    if (@($step.stats).Count -gt 0) {
        $latest = @($step.stats)[-1]
    }
    $latestStatsByThread = [ordered]@{}
    foreach ($stats in @($step.stats)) {
        if ($stats.Contains('rendererThread')) {
            $latestStatsByThread[[string]$stats.rendererThread] = $stats
        }
    }
    $activityStats = $latest
    $activityScore = -1.0
    foreach ($stats in $latestStatsByThread.Values) {
        $score = Get-StatsActivityScore $stats
        if ($score -gt $activityScore) {
            $activityScore = $score
            $activityStats = $stats
        }
    }
    $summarySteps[$key] = [ordered]@{
        pid = $step.pid
        requestedPresenter = $step.presenter
        timedOut = $step.timedOut
        sampled = $step.sampled
        exited = $step.exited
        finished = $step.finished
        completed = $step.completed
        xdgAppIds = $step.xdgAppIds
        statsSamples = @($step.stats).Count
        ignoredStatsSamples = $ignoredStats
        rendererThreadIds = @($latestStatsByThread.Keys)
        latestStatsByThread = $latestStatsByThread
        latestStats = $latest
        activityStats = $activityStats
    }
}

$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    target = $Target
    mode = $Mode
    presenter = $Presenter
    seconds = $Seconds
    iterations = $Iterations
    rawLog = $rawLogPath
    steps = $summarySteps
    statsSamples = $allStats.Count
    ignoredStatsSamples = $ignoredStats
    latestStats = if ($allStats.Count -gt 0) { $allStats[$allStats.Count - 1] } else { $null }
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-Host "[graphics-bench] rawLog=$rawLogPath"
Write-Host "[graphics-bench] json=$jsonPath"

foreach ($key in $summarySteps.Keys) {
    $step = $summarySteps[$key]
    $latest = $step.activityStats
    if ($latest) {
        Write-Host ("[graphics-bench] {0}: samples={1} timeout={2} sampled={3} threads={4} backend={5} presenter={6} snapshot={7} commit_mb={8} upload_mb={9} full_upload={10} partial_upload={11} avg_present_ms={12} avg_upload_ms={13}" -f
            $key,
            $step.statsSamples,
            $step.timedOut,
            $step.sampled,
            (($step.rendererThreadIds) -join ','),
            $latest.backend,
            $latest.presenter,
            $latest.snapshot_count,
            $latest.commit_copy_mb,
            $latest.gl_upload_mb,
            $latest.full_upload,
            $latest.partial_upload,
            $latest.avg_present_ms,
            $latest.avg_upload_ms)
    } else {
        Write-Host ("[graphics-bench] {0}: samples=0 timeout={1} sampled={2} xdg={3}" -f
            $key,
            $step.timedOut,
            $step.sampled,
            (($step.xdgAppIds | Select-Object -Unique) -join ','))
    }
}

if ($summary.latestStats) {
    $latest = $summary.latestStats
    Write-Host ("[graphics-bench] latest: samples={0} ignored={1} step={2} backend={3} presenter={4} snapshot={5} commit_mb={6} upload_mb={7} full_upload={8} partial_upload={9} skipped={10} avg_present_ms={11} avg_upload_ms={12}" -f
        $summary.statsSamples,
        $summary.ignoredStatsSamples,
        $latest.step,
        $latest.backend,
        $latest.presenter,
        $latest.snapshot_count,
        $latest.commit_copy_mb,
        $latest.gl_upload_mb,
        $latest.full_upload,
        $latest.partial_upload,
        $latest.skipped,
        $latest.avg_present_ms,
        $latest.avg_upload_ms)
}
