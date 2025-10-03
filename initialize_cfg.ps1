#initialize_cfg.ps1

$cfgPath = if ($env:PCLOUDSYNC_CONFIG) { $env:PCLOUDSYNC_CONFIG } else { Join-Path $PSScriptRoot 'userConfig.ps1' }
if (-not (Test-Path $cfgPath)) {
    throw "Configuration file '$cfgPath' not found. Copy userConfig.sample.ps1 to userConfig.ps1 and update paths."
}
. $cfgPath
if ($env:PCLOUDSYNC_CONFIG) {
    Remove-Item Env:PCLOUDSYNC_CONFIG -ErrorAction SilentlyContinue
}
. "$PSScriptRoot\logging_cfg.ps1"
. "$PSScriptRoot\gDriveProcess.ps1"
. "$PSScriptRoot\rclone_cfg.ps1"
function Initialize-Configuration {

    # Set console encoding - needed due to specific issue
    [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Initialize logging framework - check and create event log if needed
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Global:EventSource)) {
            New-EventLog -LogName $Global:LogName -Source $Global:EventSource
            Write-Log -Level INFO -Message "Event source '$Global:EventSource' created successfully."
        } else {
            # Validate the event log source
            $eventLog = Get-WmiObject -Query "SELECT * FROM Win32_NTEventLogFile WHERE LogfileName='$($Global:LogName)'"
            if (-not $eventLog) {
                Write-Log -Level WARNING -Message "Event source '$Global:EventSource' exists, but log '$Global:LogName' does not. Recreating event source."
                Remove-EventLog -Source $Global:EventSource
                New-EventLog -LogName $Global:LogName -Source $Global:EventSource
                Write-Log -Level INFO -Message "Event source '$Global:EventSource' recreated successfully."
            } else {
                Write-Log -Level INFO -Message "Event source '$Global:EventSource' and log '$Global:LogName' are valid."
            }
        }
    } catch {
        Write-Log -Level ERROR -Message "Failed to initialize event log source '$Global:EventSource': $_ `nskipping and moving to log file"
    }

    Write-Log -Level INFO -Message "**** Script initialization complete ****"

    # Handle bootstrap mode
    if ($Global:Bootstrap) {
        Write-Log -Message "Bootstrap mode enabled. Ignoring lastRun and modtime parameters." -Level INFO
        $lastrun = $null
    } else {
        $fallbackLastRun = (Get-Date "1970-01-01").ToString("yyyy-MM-dd")
        if (Test-Path $Global:FilePathLastRun) {
            $lastrun = (Get-Content -Path $Global:FilePathLastRun | Select-Object -First 1).Trim()
            if ([string]::IsNullOrWhiteSpace($lastrun)) {
                $lastrun = $fallbackLastRun
                Write-Log -Level WARNING -Message "Last run file '$($Global:FilePathLastRun)' was empty. Using fallback date $lastrun."
            }
        } else {
            $lastrun = $fallbackLastRun
            Write-Log -Level WARNING -Message "Last run file '$($Global:FilePathLastRun)' not found. Using fallback date $lastrun."
            try {
                $lastrun | Out-File -FilePath $Global:FilePathLastRun -Encoding UTF8
            } catch {
                Write-Log -Level WARNING -Message "Failed to seed last run file '$($Global:FilePathLastRun)': $_"
            }
        }
        Write-Log -Level INFO -EventID 2 -Message "Last run ts from lastrun.txt $($lastrun)"
        $Global:MaxAgeFlag = "--max-age `"$lastrun`""
    }
}
