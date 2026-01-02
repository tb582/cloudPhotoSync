[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RemoteName = 'remote',
    [string]$DedupePath,
    [switch]$SkipDedupe,
    [switch]$IgnoreMaxAge = $true
)

$ErrorActionPreference = 'Stop'
$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    $PWD.Path
}
$rootPath = Split-Path -Parent $scriptRoot
$syncScript = Join-Path $rootPath 'pcloud_sync.ps1'
if (-not $PSBoundParameters.ContainsKey('ConfigPath')) {
    $ConfigPath = Join-Path $rootPath 'userConfig.ps1'
}

if (-not (Test-Path $syncScript)) {
    throw "Unable to locate pcloud_sync.ps1 at '$syncScript'."
}

if (-not (Test-Path $ConfigPath)) {
    Write-Warning "Config file '$ConfigPath' not found. Copy userConfig.sample.ps1 to userConfig.ps1 before running the dry-run test."
    return
}

. (Join-Path $rootPath 'rclone_cfg.ps1')
$rclonePath = Resolve-RclonePath
if (-not $rclonePath) {
    throw "rclone executable not found on PATH. Install rclone or add it to PATH before running the dry-run test."
}
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Warning "rclone not found on PATH; using '$rclonePath'."
}

try {
    $syncParams = @{
        ConfigPath         = $ConfigPath
        RemoteName         = $RemoteName
        DryRun             = $true
        SkipProcessControl = $true
        FailOnRcloneError  = $true
    }

    if ($PSBoundParameters.ContainsKey('DedupePath') -and -not [string]::IsNullOrWhiteSpace($DedupePath)) {
        $syncParams.DedupePath = $DedupePath
    }
    if ($SkipDedupe) {
        $syncParams.SkipDedupe = $true
    }
    $syncParams.IgnoreMaxAge = $IgnoreMaxAge

    & $syncScript @syncParams
    Write-Host 'Dry run completed successfully.'
} catch {
    Write-Error "Dry run failed: $($_.Exception.Message)"
    throw
}
