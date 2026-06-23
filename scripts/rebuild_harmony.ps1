[CmdletBinding()]
param(
    [ValidateSet('doctor', 'full', 'incremental', 'wine', 'package', 'deploy', 'logs')]
    [string]$Mode = 'incremental',

    [ValidateSet('x86_64', 'arm64', 'all')]
    [string]$Arch = 'x86_64',

    [string]$Target = 'auto',
    [int]$WaitSeconds = 20,
    [int]$TailLines = 260,
    [string]$HdcPath = '',
    [string]$WslExe = 'wsl.exe',
    [string]$WslDistro = '',
    [switch]$NoAutoHeal,
    [switch]$SkipInstall,
    [switch]$SkipLaunch,
    [switch]$SkipLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildScript = Join-Path $RepoRoot 'scripts\rebuild_harmony.sh'
$SignedHap = Join-Path $RepoRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
$BundleName = 'app.hackeris.winehua'
$AbilityName = 'EntryAbility'
$LogPattern = 'wine|winehua_audio_smoke|MediaReg|AudioBroker|quartz|mci|mp3dmod|devenum|Alarm01|testTag|MW-NAPI|WL-|WineWM|cmd\.exe|notepad\.exe|c0000135|wineboot|wineserver|Mono|Gecko|prefix'

function Write-Info {
    param([string]$Message)
    Write-Host "[rebuild] $Message"
}

function Convert-ToWslPath {
    param([string]$WindowsPath)

    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($full -notmatch '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
        throw "Unsupported Windows path for WSL conversion: $WindowsPath"
    }

    $drive = $Matches.drive.ToLowerInvariant()
    $rest = $Matches.rest -replace '\\', '/'
    if ([string]::IsNullOrEmpty($rest)) {
        return "/mnt/$drive"
    }
    return "/mnt/$drive/$rest"
}

function Resolve-HdcPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path $RequestedPath)) {
            throw "HDC path does not exist: $RequestedPath"
        }
        return (Resolve-Path $RequestedPath).Path
    }

    $candidates = @(
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

    throw 'Unable to locate hdc.exe. Pass -HdcPath or install DevEco Studio toolchains.'
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-HdcTargets {
    param([string]$ToolPath)

    $lines = & $ToolPath list targets 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return ,@($lines | Where-Object { $_ -and $_ -ne '[Empty]' } | ForEach-Object {
        ($_ -split '\s+')[0]
    })
}

function Resolve-Target {
    param(
        [string]$ToolPath,
        [string]$RequestedTarget
    )

    if ($RequestedTarget -and $RequestedTarget -ne 'auto') {
        if ($RequestedTarget -match '^\d+\.\d+\.\d+\.\d+(?::\d+)?$') {
            $knownTargets = @(Get-HdcTargets -ToolPath $ToolPath)
            if ($knownTargets -notcontains $RequestedTarget) {
                Write-Info "hdc tconn $RequestedTarget"
                & $ToolPath tconn $RequestedTarget | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "hdc tconn failed: $RequestedTarget"
                }
            }
        }
        return $RequestedTarget
    }

    $targets = @(Get-HdcTargets -ToolPath $ToolPath)
    if ($targets.Count -eq 0) {
        throw 'No HDC targets found. Start the emulator or connect a device, or pass -Target.'
    }
    if ($targets.Count -gt 1) {
        throw "Multiple HDC targets found: $($targets -join ', '). Pass -Target explicitly."
    }
    return $targets[0]
}

function Invoke-WslBuild {
    param(
        [string]$ModeName,
        [string]$ArchName,
        [bool]$DisableAutoHeal = $false
    )

    if (-not (Test-Path $BuildScript)) {
        throw "Build script does not exist: $BuildScript"
    }

    $repoWsl = Convert-ToWslPath $RepoRoot
    $modeArg = $ModeName.Replace("'", "'""'""'")
    $archArg = $ArchName.Replace("'", "'""'""'")
    $command = "cd '$repoWsl' && bash './scripts/rebuild_harmony.sh' '$modeArg' '$archArg'"
    if ($DisableAutoHeal) {
        $command += " --no-auto-heal"
    }
    $args = @()
    if ($WslDistro) {
        $args += @('-d', $WslDistro)
    }
    $args += @('bash', '-lc', $command)

    Write-Info "WSL build: mode=$ModeName arch=$ArchName"
    Invoke-Checked -FilePath $WslExe -ArgumentList $args
}

function Install-Hap {
    param(
        [string]$ToolPath,
        [string]$ResolvedTarget
    )

    if (-not (Test-Path $SignedHap)) {
        throw "Signed HAP not found: $SignedHap"
    }

    Write-Info "Installing $SignedHap to $ResolvedTarget"
    & $ToolPath -t $ResolvedTarget uninstall -n $BundleName 2>$null
    Invoke-Checked -FilePath $ToolPath -ArgumentList @('-t', $ResolvedTarget, 'install', '-r', $SignedHap)
}

function Start-App {
    param(
        [string]$ToolPath,
        [string]$ResolvedTarget
    )

    Write-Info "Starting $BundleName/$AbilityName on $ResolvedTarget"
    Invoke-Checked -FilePath $ToolPath -ArgumentList @('-t', $ResolvedTarget, 'shell', 'aa', 'start', '-b', $BundleName, '-a', $AbilityName)
}

function Show-Logs {
    param(
        [string]$ToolPath,
        [string]$ResolvedTarget
    )

    Write-Info "Collecting filtered hilog lines from $ResolvedTarget"
    $raw = & $ToolPath -t $ResolvedTarget shell hilog -z ([string]($TailLines * 6))
    if ($LASTEXITCODE -ne 0) {
        throw "hilog read failed from $ResolvedTarget"
    }

    $matched = @($raw | Select-String $LogPattern | Select-Object -Last $TailLines | ForEach-Object { $_.Line })
    if ($matched.Count -eq 0) {
        Write-Info 'No filtered Wine logs matched; showing the raw tail instead.'
        $raw | Select-Object -Last ([Math]::Min($TailLines, 80))
        return
    }

    $matched
}

$ResolvedHdc = Resolve-HdcPath -RequestedPath $HdcPath

switch ($Mode) {
    'doctor' {
        Invoke-WslBuild -ModeName 'doctor' -ArchName $Arch
        Write-Info "HDC path: $ResolvedHdc"
        Write-Info 'Visible HDC targets:'
        $targets = @(Get-HdcTargets -ToolPath $ResolvedHdc)
        if ($targets.Count -eq 0) {
            Write-Host '[rebuild]   (none)'
        } else {
            $targets | ForEach-Object { Write-Host "[rebuild]   $_" }
        }
    }

    'full' {
        Invoke-WslBuild -ModeName 'full' -ArchName $Arch -DisableAutoHeal:$NoAutoHeal
        if (-not $SkipInstall) {
            $resolvedTarget = Resolve-Target -ToolPath $ResolvedHdc -RequestedTarget $Target
            Install-Hap -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            if (-not $SkipLaunch) {
                Start-App -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
            if (-not $SkipLogs) {
                Start-Sleep -Seconds $WaitSeconds
                Show-Logs -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
        }
    }

    'incremental' {
        Invoke-WslBuild -ModeName 'incremental' -ArchName $Arch -DisableAutoHeal:$NoAutoHeal
        if (-not $SkipInstall) {
            $resolvedTarget = Resolve-Target -ToolPath $ResolvedHdc -RequestedTarget $Target
            Install-Hap -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            if (-not $SkipLaunch) {
                Start-App -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
            if (-not $SkipLogs) {
                Start-Sleep -Seconds $WaitSeconds
                Show-Logs -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
        }
    }

    'wine' {
        Invoke-WslBuild -ModeName 'wine' -ArchName $Arch -DisableAutoHeal:$NoAutoHeal
        if (-not $SkipInstall) {
            $resolvedTarget = Resolve-Target -ToolPath $ResolvedHdc -RequestedTarget $Target
            Install-Hap -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            if (-not $SkipLaunch) {
                Start-App -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
            if (-not $SkipLogs) {
                Start-Sleep -Seconds $WaitSeconds
                Show-Logs -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
        }
    }

    'package' {
        Invoke-WslBuild -ModeName 'package' -ArchName $Arch -DisableAutoHeal:$NoAutoHeal
        if (-not $SkipInstall) {
            $resolvedTarget = Resolve-Target -ToolPath $ResolvedHdc -RequestedTarget $Target
            Install-Hap -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            if (-not $SkipLaunch) {
                Start-App -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
            if (-not $SkipLogs) {
                Start-Sleep -Seconds $WaitSeconds
                Show-Logs -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
            }
        }
    }

    'deploy' {
        $resolvedTarget = Resolve-Target -ToolPath $ResolvedHdc -RequestedTarget $Target
        Install-Hap -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
        if (-not $SkipLaunch) {
            Start-App -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
        }
        if (-not $SkipLogs) {
            Start-Sleep -Seconds $WaitSeconds
            Show-Logs -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
        }
    }

    'logs' {
        $resolvedTarget = Resolve-Target -ToolPath $ResolvedHdc -RequestedTarget $Target
        Show-Logs -ToolPath $ResolvedHdc -ResolvedTarget $resolvedTarget
    }
}
