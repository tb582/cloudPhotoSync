function Stop-GoogleDriveFS {
    param (
        [switch]$DryRun  # Add a DryRun switch for simulation mode
    )

    $processName = 'GoogleDriveFS'

    Write-Log -Level INFO -Message "Attempting to stop $processName..."

    # Locate the executable file (used for starting the process later)
    $driveRoot = Join-Path $env:ProgramFiles 'Google\Drive File Stream'
    if (-not (Test-Path $driveRoot)) {
        Write-Log -Level WARNING -Message "Google Drive File Stream not found at $driveRoot. Skipping $processName control."
        return
    }
    $processPath = Get-ChildItem $driveRoot -Filter 'GoogleDriveFS.exe' -Recurse |
        Sort-Object LastWriteTime | Select-Object -Last 1 | Select-Object -ExpandProperty FullName

    if (-not $processPath) {
        Write-Log -Level WARNING -Message "Could not find the GoogleDriveFS executable. Assuming $processName is not installed."
        return
    } else {
        Write-Log -Level DEBUG -Message "Located GoogleDriveFS executable at: $processPath"
    }

    if ($DryRun) {
        Write-Log -Level INFO -Message "Dry-run mode: Simulating termination of $processName processes."
        return
    }

    # Get all existing processes of interest
    $processes = Get-Process -ErrorAction SilentlyContinue -Name $processName
    if (-not $processes) {
        Write-Log -Level INFO -Message "No $processName processes are currently running."
        return
    }

    # Attempt to stop processes using Stop-Process
    try {
        Write-Log -Level INFO -Message "Attempting to terminate $processName processes..."
        $processes | Stop-Process -Force
        
        # Wait and verify
        Start-Sleep -Seconds 2
        $remainingProcesses = Get-Process -ErrorAction SilentlyContinue -Name $processName
        
        if ($remainingProcesses) {
            Write-Log -Level ERROR -Message "Unable to stop $processName processes. Exiting script."
            Exit 1
        } else {
            Write-Log -Level INFO -Message "$processName processes terminated successfully."
        }
    }
    catch {
        Write-Log -Level ERROR -Message "Error occurred while terminating ${processName}: $_"
        Exit 1
    }
}


function Start-GoogleDriveFS {
    param (
        [switch]$DryRun  # Add a DryRun switch for simulation mode
    )

    $processName = 'GoogleDriveFS'

    # Locate the latest executable file for starting the process
    $driveRoot = Join-Path $env:ProgramFiles 'Google\Drive File Stream'
    if (-not (Test-Path $driveRoot)) {
        Write-Log -Level WARNING -Message "Google Drive File Stream not found at $driveRoot. Skipping $processName start."
        return
    }
    $processPath = Get-ChildItem $driveRoot -Filter 'GoogleDriveFS.exe' -Recurse |
        Sort-Object LastWriteTime | Select-Object -Last 1 | Select-Object -ExpandProperty FullName

    if (-not $processPath) {
        Write-Log -Level ERROR -Message "Could not find the $processName executable."
        return
    } else {
        Write-Log -Level DEBUG -Message "Located GoogleDriveFS executable at: $processPath"
    }

    if ($DryRun) {
        Write-Log -Level INFO -Message "Dry-run mode: Simulating starting of $processName from $processPath."
        return
    }

    # Start GoogleDriveFS
    try {
        Write-Log -Level INFO -Message "Starting $processName from $processPath"
        $process = Start-Process -FilePath $processPath -PassThru
        Start-Sleep -Seconds 5  # Give the process some time to start

        # Verify the process is running
        if ($process.HasExited) {
            Write-Log -Level ERROR -Message "$processName failed to start. Exit code: $($process.ExitCode)"
        } else {
            Write-Log -Level INFO -Message "$processName started successfully with PID: $($process.Id)."
        }
    } catch {
        Write-Log -Level ERROR -Message "An error occurred while starting ${processName}: $_"
    }
}
