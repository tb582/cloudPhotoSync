[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'userConfig.ps1'),
    [string]$RemoteName = 'remote'
)

$ErrorActionPreference = 'Stop'
$rootPath = Split-Path -Parent $PSScriptRoot
$syncScript = Join-Path $rootPath 'pcloud_sync.ps1'

if (-not (Test-Path $syncScript)) {
    throw "Unable to locate pcloud_sync.ps1 at '$syncScript'."
}

if (-not (Test-Path $ConfigPath)) {
    Write-Warning "Config file '$ConfigPath' not found. Copy userConfig.sample.ps1 to userConfig.ps1 before running the dry-run test."
    return
}

try {
    $syncParams = @{
        ConfigPath         = $ConfigPath
        RemoteName         = $RemoteName
        DryRun             = $true
        SkipProcessControl = $true
    }

    & $syncScript @syncParams
    Write-Host 'Dry run completed successfully.'
} catch {
    Write-Error "Dry run failed: $($_.Exception.Message)"
    throw
}
