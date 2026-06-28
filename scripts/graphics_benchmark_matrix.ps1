<#
.SYNOPSIS
Run an A/B graphics presenter benchmark matrix and write JSON/Markdown reports.

.DESCRIPTION
Runs a warm-up pass, then repeats direct Wine launches for the requested frame
presenters. The direct Wine path is the primary correctness/performance signal.
Explorer can be sampled as an optional compatibility observation, but it is not
included in the primary A/B estimate.
#>
[CmdletBinding()]
param(
    [string]$Target = '127.0.0.1:5555',
    [string]$HdcPath = '',
    [ValidateSet('cpu_shm_upload', 'gl_compositor_direct', 'auto')]
    [string[]]$Presenters = @('cpu_shm_upload', 'gl_compositor_direct'),
    [int]$Seconds = 10,
    [int]$Iterations = 3,
    [int]$WarmupSeconds = 4,
    [int]$WaitSeconds = 120,
    [switch]$NoWarmup,
    [switch]$IncludeExplorerObservation,
    [string]$OutDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BenchScript = Join-Path $PSScriptRoot 'graphics_benchmark.ps1'
if (-not $OutDir) {
    $OutDir = Join-Path $RepoRoot 'out\graphics-benchmarks'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Get-PropValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
}

function Get-Number {
    param(
        [object]$Object,
        [string]$Name,
        [double]$Default = 0.0
    )

    $value = Get-PropValue $Object $Name $null
    if ($null -eq $value) { return $Default }
    return [double]$value
}

function Get-Median {
    param([double[]]$Values)

    $valid = @($Values | Where-Object { -not [double]::IsNaN($_) } | Sort-Object)
    if ($valid.Count -eq 0) { return $null }
    $mid = [int]($valid.Count / 2)
    if (($valid.Count % 2) -eq 1) { return [double]$valid[$mid] }
    return ([double]$valid[$mid - 1] + [double]$valid[$mid]) / 2.0
}

function Get-Mean {
    param([double[]]$Values)

    $valid = @($Values | Where-Object { -not [double]::IsNaN($_) })
    if ($valid.Count -eq 0) { return $null }
    return (($valid | Measure-Object -Average).Average)
}

function Format-NullableNumber {
    param(
        [object]$Value,
        [int]$Digits = 2
    )

    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString("F$Digits", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-StepEntries {
    param([object]$Summary)

    $entries = @()
    $steps = Get-PropValue $Summary 'steps' $null
    if ($null -eq $steps) { return $entries }

    foreach ($prop in $steps.PSObject.Properties) {
        $entries += [pscustomobject]@{
            Name = $prop.Name
            Step = $prop.Value
        }
    }
    return $entries
}

function Convert-BenchmarkSummary {
    param(
        [object]$Summary,
        [string]$RequestedPresenter,
        [string]$Role
    )

    $entries = Get-StepEntries $Summary
    $records = @()

    foreach ($entry in $entries) {
        $stats = Get-PropValue $entry.Step 'activityStats' $null
        $snapshotCount = Get-Number $stats 'snapshot_count'
        $commitCopyMb = Get-Number $stats 'commit_copy_mb'
        $snapshotCopyMb = Get-Number $stats 'snapshot_copy_mb'
        $totalCpuCopyMb = Get-Number $stats 'total_cpu_copy_mb'
        $glUploadMb = Get-Number $stats 'gl_upload_mb'
        $fullUpload = Get-Number $stats 'full_upload'
        $partialUpload = Get-Number $stats 'partial_upload'
        $uploadDenominator = [math]::Max($fullUpload + $partialUpload, 1.0)
        $records += [pscustomobject]@{
            role = $Role
            mode = Get-PropValue $Summary 'mode' ''
            requestedPresenter = $RequestedPresenter
            stepRequestedPresenter = Get-PropValue $entry.Step 'requestedPresenter' $RequestedPresenter
            step = $entry.Name
            pid = Get-PropValue $entry.Step 'pid' $null
            finished = [bool](Get-PropValue $entry.Step 'finished' $false)
            timedOut = [bool](Get-PropValue $entry.Step 'timedOut' $false)
            sampled = [bool](Get-PropValue $entry.Step 'sampled' $false)
            completed = [bool](Get-PropValue $entry.Step 'completed' $false)
            statsSamples = [int](Get-PropValue $entry.Step 'statsSamples' 0)
            backend = Get-PropValue $stats 'backend' ''
            presenter = Get-PropValue $stats 'presenter' ''
            snapshotCount = $snapshotCount
            commitCopyMb = $commitCopyMb
            snapshotCopyMb = $snapshotCopyMb
            totalCpuCopyMb = $totalCpuCopyMb
            glUploadMb = $glUploadMb
            fullUpload = $fullUpload
            partialUpload = $partialUpload
            skipped = Get-Number $stats 'skipped'
            damageRects = Get-Number $stats 'damage_rects'
            avgPresentMs = Get-Number $stats 'avg_present_ms'
            avgUploadMs = Get-Number $stats 'avg_upload_ms'
            commitCopyMbPerUpload = $commitCopyMb / $uploadDenominator
            snapshotCopyMbPerUpload = $snapshotCopyMb / $uploadDenominator
            totalCpuCopyMbPerUpload = $totalCpuCopyMb / $uploadDenominator
            glUploadMbPerUpload = $glUploadMb / $uploadDenominator
            rawLog = Get-PropValue $Summary 'rawLog' ''
            json = $Summary.__jsonPath
        }
    }

    return $records
}

function Invoke-OneBenchmark {
    param(
        [string]$Mode,
        [string]$Presenter,
        [int]$RunSeconds,
        [string]$Role
    )

    $start = Get-Date
    $args = @(
        '-Target', $Target,
        '-Mode', $Mode,
        '-Presenter', $Presenter,
        '-Seconds', $RunSeconds,
        '-Iterations', 1,
        '-WaitSeconds', $WaitSeconds,
        '-OutDir', $OutDir
    )
    if ($HdcPath) {
        $args += @('-HdcPath', $HdcPath)
    }

    Write-Host "[graphics-matrix] run role=$Role mode=$Mode presenter=$Presenter seconds=$RunSeconds"
    $benchOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $BenchScript @args 2>&1
    $benchExitCode = $LASTEXITCODE
    foreach ($line in $benchOutput) {
        Write-Host $line
    }
    if ($benchExitCode -ne 0) {
        throw "graphics_benchmark.ps1 failed for role=$Role mode=$Mode presenter=$Presenter"
    }

    $jsonFile = Get-ChildItem -LiteralPath $OutDir -Filter 'graphics-benchmark-*.json' |
        Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $jsonFile) {
        throw "No benchmark JSON was produced for role=$Role mode=$Mode presenter=$Presenter"
    }

    $summary = Get-Content -LiteralPath $jsonFile.FullName -Raw | ConvertFrom-Json
    $summary | Add-Member -NotePropertyName '__jsonPath' -NotePropertyValue $jsonFile.FullName -Force
    return Convert-BenchmarkSummary -Summary $summary -RequestedPresenter $Presenter -Role $Role
}

function Build-Aggregate {
    param([object[]]$Records)

    $groups = $Records |
        Where-Object { $_.PSObject.Properties['role'] -and $_.PSObject.Properties['statsSamples'] } |
        Where-Object { $_.role -eq 'primary' -and $_.statsSamples -gt 0 } |
        Group-Object requestedPresenter

    $aggregates = @()
    foreach ($group in $groups) {
        $rows = @($group.Group)
        $aggregates += [pscustomobject]@{
            presenter = $group.Name
            runs = $rows.Count
            finished = @($rows | Where-Object { $_.finished }).Count
            timedOut = @($rows | Where-Object { $_.timedOut }).Count
            actualPresenters = (($rows | Select-Object -ExpandProperty presenter -Unique) -join ',')
            medianCommitCopyMb = Get-Median @($rows | ForEach-Object { [double]$_.commitCopyMb })
            medianSnapshotCopyMb = Get-Median @($rows | ForEach-Object { [double]$_.snapshotCopyMb })
            medianTotalCpuCopyMb = Get-Median @($rows | ForEach-Object { [double]$_.totalCpuCopyMb })
            medianGlUploadMb = Get-Median @($rows | ForEach-Object { [double]$_.glUploadMb })
            medianFullUpload = Get-Median @($rows | ForEach-Object { [double]$_.fullUpload })
            medianPartialUpload = Get-Median @($rows | ForEach-Object { [double]$_.partialUpload })
            medianAvgPresentMs = Get-Median @($rows | ForEach-Object { [double]$_.avgPresentMs })
            medianAvgUploadMs = Get-Median @($rows | ForEach-Object { [double]$_.avgUploadMs })
            medianCommitCopyMbPerUpload = Get-Median @($rows | ForEach-Object { [double]$_.commitCopyMbPerUpload })
            medianSnapshotCopyMbPerUpload = Get-Median @($rows | ForEach-Object { [double]$_.snapshotCopyMbPerUpload })
            medianTotalCpuCopyMbPerUpload = Get-Median @($rows | ForEach-Object { [double]$_.totalCpuCopyMbPerUpload })
            medianGlUploadMbPerUpload = Get-Median @($rows | ForEach-Object { [double]$_.glUploadMbPerUpload })
            meanCommitCopyMb = Get-Mean @($rows | ForEach-Object { [double]$_.commitCopyMb })
            meanGlUploadMb = Get-Mean @($rows | ForEach-Object { [double]$_.glUploadMb })
            meanAvgPresentMs = Get-Mean @($rows | ForEach-Object { [double]$_.avgPresentMs })
            meanAvgUploadMs = Get-Mean @($rows | ForEach-Object { [double]$_.avgUploadMs })
        }
    }
    return $aggregates
}

function Get-ReductionPct {
    param(
        [object]$Baseline,
        [object]$Candidate,
        [string]$Metric
    )

    if ($null -eq $Baseline -or $null -eq $Candidate) { return $null }
    $base = Get-PropValue $Baseline $Metric $null
    $cand = Get-PropValue $Candidate $Metric $null
    if ($null -eq $base -or $null -eq $cand) { return $null }
    if ([double]$base -eq 0.0) { return $null }
    return (([double]$base - [double]$cand) / [double]$base) * 100.0
}

function Write-MatrixReport {
    param(
        [string]$Path,
        [object[]]$Records,
        [object[]]$Aggregates,
        [object]$Improvement
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# WineHua Graphics Benchmark Matrix")
    $lines.Add("")
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add("")
    $lines.Add("Primary baseline: direct Wine launch of C:\winehua_graphics_smoke.exe. Explorer launches are treated as compatibility observations only.")
    $lines.Add("")
    $lines.Add("## Run Config")
    $lines.Add("")
    $lines.Add('- Target: `' + $Target + '`')
    $lines.Add('- Seconds per primary run: `' + $Seconds + '`')
    $lines.Add('- Iterations per presenter: `' + $Iterations + '`')
    $lines.Add('- Presenters: `' + ($Presenters -join ', ') + '`')
    $lines.Add('- Explorer observation: `' + ([bool]$IncludeExplorerObservation) + '`')
    $lines.Add("")
    $lines.Add("## Aggregate")
    $lines.Add("")
    $lines.Add("| presenter | runs | actual | timeout | commit MB | snapshot MB | cpu copy MB | GL upload MB | full | partial | present ms | upload ms |")
    $lines.Add("|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    foreach ($agg in $Aggregates) {
        $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |" -f
            $agg.presenter,
            $agg.runs,
            $agg.actualPresenters,
            $agg.timedOut,
            (Format-NullableNumber $agg.medianCommitCopyMb),
            (Format-NullableNumber $agg.medianSnapshotCopyMb),
            (Format-NullableNumber $agg.medianTotalCpuCopyMb),
            (Format-NullableNumber $agg.medianGlUploadMb),
            (Format-NullableNumber $agg.medianFullUpload 0),
            (Format-NullableNumber $agg.medianPartialUpload 0),
            (Format-NullableNumber $agg.medianAvgPresentMs),
            (Format-NullableNumber $agg.medianAvgUploadMs)))
    }
    $lines.Add("")
    $lines.Add("## Estimated Change")
    $lines.Add("")
    if ($Improvement) {
        $lines.Add(("- GL direct vs CPU fallback, median GL upload reduction: {0}%" -f (Format-NullableNumber $Improvement.glUploadReductionPct)))
        $lines.Add(("- GL direct vs CPU fallback, median snapshot copy reduction: {0}%" -f (Format-NullableNumber $Improvement.snapshotCopyReductionPct)))
        $lines.Add(("- GL direct vs CPU fallback, median total CPU copy reduction: {0}%" -f (Format-NullableNumber $Improvement.totalCpuCopyReductionPct)))
        $lines.Add(("- GL direct vs CPU fallback, median present time change: {0}%" -f (Format-NullableNumber $Improvement.presentMsReductionPct)))
    } else {
        $lines.Add("- Not enough CPU and GL direct data to estimate a paired improvement.")
    }
    $lines.Add("")
    $lines.Add("## Runs")
    $lines.Add("")
    $lines.Add("| role | presenter | actual | step | finished | timeout | sampled | commit MB | GL upload MB | full | partial | present ms | upload ms | json |")
    $lines.Add("|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    foreach ($record in $Records) {
        $jsonName = Split-Path -Leaf $record.json
        $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} |" -f
            $record.role,
            $record.requestedPresenter,
            $record.presenter,
            $record.step,
            $record.finished,
            $record.timedOut,
            $record.sampled,
            (Format-NullableNumber $record.commitCopyMb),
            (Format-NullableNumber $record.glUploadMb),
            (Format-NullableNumber $record.fullUpload 0),
            (Format-NullableNumber $record.partialUpload 0),
            (Format-NullableNumber $record.avgPresentMs),
            (Format-NullableNumber $record.avgUploadMs),
            $jsonName))
    }
    $lines.Add("")
    $lines.Add("## Reading")
    $lines.Add("")
    $lines.Add('- The current best low-risk scheme is `gl_compositor_direct` when it is functional, because it removes the compositor snapshot path and enables texture-cache/damage accounting.')
    $lines.Add('- `commit_copy_mb` is still wl_shm commit-side copy cost; GL direct does not remove it yet.')
    $lines.Add("- Direct smoke is the primary correctness signal. Explorer launch errors should be fixed separately before using explorer data as a baseline.")

    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$matrixJsonPath = Join-Path $OutDir "graphics-benchmark-matrix-$timestamp.json"
$matrixReportPath = Join-Path $OutDir "graphics-benchmark-matrix-$timestamp.md"

$records = @()
if (-not $NoWarmup) {
    $records += Invoke-OneBenchmark -Mode 'graphics-direct' -Presenter 'gl_compositor_direct' -RunSeconds $WarmupSeconds -Role 'warmup'
}

foreach ($presenter in $Presenters) {
    for ($i = 1; $i -le $Iterations; $i++) {
        $records += Invoke-OneBenchmark -Mode 'graphics-direct' -Presenter $presenter -RunSeconds $Seconds -Role 'primary'
    }
}

if ($IncludeExplorerObservation) {
    $records += Invoke-OneBenchmark -Mode 'graphics-explorer' -Presenter 'gl_compositor_direct' -RunSeconds $Seconds -Role 'explorer-observation'
}

$aggregates = @(Build-Aggregate -Records $records)
$baseline = $aggregates | Where-Object { $_.presenter -eq 'cpu_shm_upload' } | Select-Object -First 1
$candidate = $aggregates | Where-Object { $_.presenter -eq 'gl_compositor_direct' } | Select-Object -First 1
$improvement = $null
if ($baseline -and $candidate) {
    $improvement = [pscustomobject]@{
        baseline = 'cpu_shm_upload'
        candidate = 'gl_compositor_direct'
        glUploadReductionPct = Get-ReductionPct $baseline $candidate 'medianGlUploadMb'
        snapshotCopyReductionPct = Get-ReductionPct $baseline $candidate 'medianSnapshotCopyMb'
        totalCpuCopyReductionPct = Get-ReductionPct $baseline $candidate 'medianTotalCpuCopyMb'
        presentMsReductionPct = Get-ReductionPct $baseline $candidate 'medianAvgPresentMs'
        glUploadPerUploadReductionPct = Get-ReductionPct $baseline $candidate 'medianGlUploadMbPerUpload'
        snapshotCopyPerUploadReductionPct = Get-ReductionPct $baseline $candidate 'medianSnapshotCopyMbPerUpload'
        totalCpuCopyPerUploadReductionPct = Get-ReductionPct $baseline $candidate 'medianTotalCpuCopyMbPerUpload'
    }
}

$matrix = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    target = $Target
    seconds = $Seconds
    iterations = $Iterations
    warmupSeconds = $WarmupSeconds
    presenters = $Presenters
    includeExplorerObservation = [bool]$IncludeExplorerObservation
    records = $records
    aggregates = $aggregates
    improvement = $improvement
    report = $matrixReportPath
}

$matrix | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $matrixJsonPath -Encoding UTF8
Write-MatrixReport -Path $matrixReportPath -Records $records -Aggregates $aggregates -Improvement $improvement

Write-Host "[graphics-matrix] json=$matrixJsonPath"
Write-Host "[graphics-matrix] report=$matrixReportPath"
foreach ($agg in $aggregates) {
    Write-Host ("[graphics-matrix] presenter={0} runs={1} actual={2} commit_mb={3} upload_mb={4} present_ms={5} upload_ms={6}" -f
        $agg.presenter,
        $agg.runs,
        $agg.actualPresenters,
        (Format-NullableNumber $agg.medianCommitCopyMb),
        (Format-NullableNumber $agg.medianGlUploadMb),
        (Format-NullableNumber $agg.medianAvgPresentMs),
        (Format-NullableNumber $agg.medianAvgUploadMs))
}
if ($improvement) {
    Write-Host ("[graphics-matrix] gl_direct_vs_cpu upload_reduction={0}% snapshot_copy_reduction={1}% total_cpu_copy_reduction={2}% present_ms_change={3}%" -f
        (Format-NullableNumber $improvement.glUploadReductionPct),
        (Format-NullableNumber $improvement.snapshotCopyReductionPct),
        (Format-NullableNumber $improvement.totalCpuCopyReductionPct),
        (Format-NullableNumber $improvement.presentMsReductionPct))
}
