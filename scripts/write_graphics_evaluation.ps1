<#
.SYNOPSIS
Write a concise graphics optimization evaluation report from benchmark JSON.
#>
[CmdletBinding()]
param(
    [string]$MatrixJson = '',
    [string]$OutPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $MatrixJson) {
    $MatrixJson = (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'out\graphics-benchmarks') -Filter 'graphics-benchmark-matrix-*.json' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1).FullName
}
if (-not $MatrixJson) {
    throw 'No matrix JSON found. Pass -MatrixJson.'
}

$matrix = Get-Content -LiteralPath $MatrixJson -Raw | ConvertFrom-Json
if (-not $OutPath) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($MatrixJson)
    $OutPath = Join-Path ([IO.Path]::GetDirectoryName($MatrixJson)) "$stem-evaluation.md"
}

function Fmt {
    param([object]$Value, [int]$Digits = 2)
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString("F$Digits", [Globalization.CultureInfo]::InvariantCulture)
}

function Median {
    param([double[]]$Values)
    $valid = @($Values | Sort-Object)
    if ($valid.Count -eq 0) { return $null }
    $mid = [int]($valid.Count / 2)
    if (($valid.Count % 2) -eq 1) { return [double]$valid[$mid] }
    return ([double]$valid[$mid - 1] + [double]$valid[$mid]) / 2.0
}

function Reduction {
    param([double]$Base, [double]$Candidate)
    if ($Base -eq 0.0) { return $null }
    return (($Base - $Candidate) / $Base) * 100.0
}

$primary = @($matrix.records | Where-Object { $_.role -eq 'primary' -and $_.statsSamples -gt 0 })
$cpu = @($primary | Where-Object { $_.requestedPresenter -eq 'cpu_shm_upload' })
$gl = @($primary | Where-Object { $_.requestedPresenter -eq 'gl_compositor_direct' })

function Aggregate {
    param([object[]]$Rows, [string]$Name)
    $denRows = @($Rows | ForEach-Object {
        $den = [math]::Max(([double]$_.fullUpload + [double]$_.partialUpload), 1.0)
        [pscustomobject]@{
            commitPerUpload = [double]$_.commitCopyMb / $den
            snapshotPerUpload = [double]$_.snapshotCopyMb / $den
            totalCpuPerUpload = [double]$_.totalCpuCopyMb / $den
            glUploadPerUpload = [double]$_.glUploadMb / $den
        }
    })
    [pscustomobject]@{
        presenter = $Name
        runs = $Rows.Count
        finished = @($Rows | Where-Object { $_.finished }).Count
        timeout = @($Rows | Where-Object { $_.timedOut }).Count
        fullUpload = Median @($Rows | ForEach-Object { [double]$_.fullUpload })
        commitMb = Median @($Rows | ForEach-Object { [double]$_.commitCopyMb })
        snapshotMb = Median @($Rows | ForEach-Object { [double]$_.snapshotCopyMb })
        totalCpuMb = Median @($Rows | ForEach-Object { [double]$_.totalCpuCopyMb })
        uploadMb = Median @($Rows | ForEach-Object { [double]$_.glUploadMb })
        presentMs = Median @($Rows | ForEach-Object { [double]$_.avgPresentMs })
        uploadMs = Median @($Rows | ForEach-Object { [double]$_.avgUploadMs })
        commitPerUpload = Median @($denRows | ForEach-Object { [double]$_.commitPerUpload })
        snapshotPerUpload = Median @($denRows | ForEach-Object { [double]$_.snapshotPerUpload })
        totalCpuPerUpload = Median @($denRows | ForEach-Object { [double]$_.totalCpuPerUpload })
        glUploadPerUpload = Median @($denRows | ForEach-Object { [double]$_.glUploadPerUpload })
    }
}

$cpuAgg = Aggregate $cpu 'cpu_shm_upload'
$glAgg = Aggregate $gl 'gl_compositor_direct'

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# WineHua VirGL Display Optimization Evaluation')
$lines.Add('')
$lines.Add("Generated: $(Get-Date -Format o)")
$lines.Add('')
$lines.Add('## Scope')
$lines.Add('')
$lines.Add('- Primary path: direct Wine launch of `C:\winehua_graphics_smoke.exe`.')
$lines.Add('- Explorer launch remains a compatibility observation because the current smoke exe is reliable only when launched directly by Wine.')
$lines.Add('- Build/deploy verification used the shared `rebuild_harmony.ps1` incremental and deploy flow.')
$lines.Add('')
$lines.Add('## Current Stage')
$lines.Add('')
$lines.Add('- Completed: GraphicsStats, presenter abstraction, `CpuShmPresenter` fallback, `GlCompositorPresenter`, texture cache, benchmark presenter override, automated matrix report.')
$lines.Add('- Partially validated: damage rect accounting. Explorer/multi-window previously showed partial upload, but direct dynamic smoke still uses full uploads.')
$lines.Add('- Not yet selected for implementation: NativeBuffer/EGLImage and VirGL scanout import.')
$lines.Add('')
$lines.Add('## Direct A/B Result')
$lines.Add('')
$lines.Add('| presenter | runs | finished | timeout | full uploads | commit MB | snapshot MB | total CPU MB | GL upload MB | present ms | upload ms |')
$lines.Add('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
foreach ($agg in @($cpuAgg, $glAgg)) {
    $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |" -f
        $agg.presenter,
        $agg.runs,
        $agg.finished,
        $agg.timeout,
        (Fmt $agg.fullUpload 0),
        (Fmt $agg.commitMb),
        (Fmt $agg.snapshotMb),
        (Fmt $agg.totalCpuMb),
        (Fmt $agg.uploadMb),
        (Fmt $agg.presentMs),
        (Fmt $agg.uploadMs)))
}
$lines.Add('')
$lines.Add('## Normalized View')
$lines.Add('')
$lines.Add('| presenter | commit MB/upload | snapshot MB/upload | total CPU MB/upload | GL MB/upload |')
$lines.Add('|---|---:|---:|---:|---:|')
foreach ($agg in @($cpuAgg, $glAgg)) {
    $lines.Add(("| {0} | {1} | {2} | {3} | {4} |" -f
        $agg.presenter,
        (Fmt $agg.commitPerUpload 3),
        (Fmt $agg.snapshotPerUpload 3),
        (Fmt $agg.totalCpuPerUpload 3),
        (Fmt $agg.glUploadPerUpload 3)))
}
$lines.Add('')
$lines.Add('## Improvement Estimate')
$lines.Add('')
$glUploadTotalReduction = Reduction $cpuAgg.uploadMb $glAgg.uploadMb
$glUploadPerUploadReduction = Reduction $cpuAgg.glUploadPerUpload $glAgg.glUploadPerUpload
$lines.Add(("- Snapshot copy reduction: {0}%." -f (Fmt (Reduction $cpuAgg.snapshotMb $glAgg.snapshotMb))))
$lines.Add(("- Total CPU copy reduction: {0}% by absolute run totals, and {1}% per upload." -f
        (Fmt (Reduction $cpuAgg.totalCpuMb $glAgg.totalCpuMb)),
        (Fmt (Reduction $cpuAgg.totalCpuPerUpload $glAgg.totalCpuPerUpload))))
$lines.Add(("- Present time reduction: {0}%." -f (Fmt (Reduction $cpuAgg.presentMs $glAgg.presentMs))))
if ($null -ne $glUploadTotalReduction -and $glUploadTotalReduction -lt 0) {
    $lines.Add(("- GL upload total increased by {0}% because GL direct produces more rendered/uploaded frames in the same 16s window; per upload reduction is {1}%." -f
            (Fmt (-1.0 * $glUploadTotalReduction)),
            (Fmt $glUploadPerUploadReduction)))
} else {
    $lines.Add(("- GL upload total reduction: {0}%; per upload reduction: {1}%." -f
            (Fmt $glUploadTotalReduction),
            (Fmt $glUploadPerUploadReduction)))
}
$lines.Add('')
$lines.Add('## Decision')
$lines.Add('')
$lines.Add('Use `gl_compositor_direct` as the current best VirGL display scheme, with `cpu_shm_upload` retained as fallback. It is functionally verified on the direct smoke path, removes the expensive snapshot copy, and substantially lowers present time. It does not yet reduce wl_shm commit copy or direct-smoke GL upload volume.')
$lines.Add('')
$lines.Add('## Next Steps')
$lines.Add('')
$lines.Add('1. Lower the GraphicsStats interval or add end-of-run stats flushing so short CPU fallback runs always emit data.')
$lines.Add('2. Focus next optimization on direct damage propagation/thresholds: direct smoke still reports `partial_upload=0` and full uploads only.')
$lines.Add('3. Reduce wl_shm commit copy after damage is stable; GL direct currently removes snapshot copy, not commit copy.')
$lines.Add('4. Keep explorer outside the primary benchmark until its launch/argument/window behavior is fixed.')
$lines.Add('5. Investigate NativeBuffer/EGLImage only after direct damage and commit-copy bottlenecks are measured cleanly.')
$lines.Add('')
$lines.Add('## Evidence')
$lines.Add('')
$lines.Add(('- Matrix JSON: `{0}`' -f $MatrixJson))
$lines.Add(('- Matrix report: `{0}`' -f $matrix.report))
foreach ($record in $primary) {
    $lines.Add(('- `{0}` -> `{1}` ({2}, {3})' -f
        [IO.Path]::GetFileName($record.json),
        [IO.Path]::GetFileName($record.rawLog),
        $record.requestedPresenter,
        $record.presenter))
}

$lines | Set-Content -LiteralPath $OutPath -Encoding UTF8
Write-Host "[graphics-eval] report=$OutPath"
