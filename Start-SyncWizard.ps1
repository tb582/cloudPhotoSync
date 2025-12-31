[CmdletBinding()]
param(
    [string]$ConfigOutputPath
)

if ($PSVersionTable.PSEdition -ne 'Desktop' -and $IsWindows -ne $true) {
    throw 'Sync wizard requires Windows.'
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $hostPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $hostPath) {
        $hostPath = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source
    }
    if (-not $hostPath) {
        throw 'No PowerShell host found to relaunch the wizard in STA mode.'
    }

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $args = @('-NoLogo','-NoProfile','-STA','-File', "`"$scriptPath`"")
    if ($PSBoundParameters.ContainsKey('ConfigOutputPath')) {
        $args += @('-ConfigOutputPath', "`"$ConfigOutputPath`"")
    }

    Start-Process -FilePath $hostPath -ArgumentList $args | Out-Null
    return
}

$modulePath = Join-Path $PSScriptRoot 'ui\SyncWizard.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Sync wizard module not found at $modulePath."
}

if (-not $PSBoundParameters.ContainsKey('ConfigOutputPath') -or [string]::IsNullOrWhiteSpace($ConfigOutputPath)) {
    $ConfigOutputPath = Join-Path $PSScriptRoot 'userConfig.ps1'
}

Import-Module $modulePath -Force

$result = Start-SyncWizard -ConfigOutputPath $ConfigOutputPath

if ($result) {
    Write-Host "Wizard complete. Configuration saved to $($result.ConfigPath)."
    if ($result.SyncStarted) {
        Write-Host "pcloud_sync.ps1 was launched in a new window."
    }
} else {
    Write-Host "Wizard cancelled."
}
