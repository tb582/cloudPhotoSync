# rclone_cfg.ps1

function Execute-RcloneCommand {
    param (
        [string]$Command,
        [string]$Arguments,
        [string]$LogFile = $global:LogFile,                # Main script log file
        [string]$RcloneLogFilePath,                        # rclone's internal log file (--log-file)
        [string]$StdOutFilePath = $Global:StdOutFilePath,  # Final stdout log file (fallback)
        [string]$StdErrFilePath = $Global:StdErrFilePath,  # Final stderr log file (fallback)
        [int]$LogIntervalSeconds = 5,                      # Throttle interval for monitoring the log file
        [int]$MaxInactivityTime = 300,                     # Maximum inactivity time (no new log entries) in seconds
        [int]$MaxRetries = 3,                              # Number of retries for rclone errors
        [int]$WaitTimeoutMs = 600000                       # Timeout for process exit (in milliseconds, default: 10 min)
    )

    # Initialize retry variables
    $retryCount = 0
    $commandSucceeded = $false
    $finalExitCode = $null
    $stdoutContent = @() # Initialize stdout content as an empty array

    do {
        # Build the full rclone arguments
        if ([string]::IsNullOrWhiteSpace($RcloneLogFilePath)) {
            $FullArguments = "$Arguments --log-level DEBUG"
        } else {
            $FullArguments = "$Arguments --log-file=$RcloneLogFilePath --log-level DEBUG"
        }
        Write-Log -Level DEBUG -Message "Preparing to execute rclone command: `nrclone $Command $FullArguments" -LogFile $LogFile

        # Track start time and last progress time
        $startTime = Get-Date
        $lastProgressTime = $startTime

        try {
            # Start the rclone process with redirected output
            $process = Start-Process -FilePath "rclone" -ArgumentList "$Command $FullArguments" `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput $StdOutFilePath -RedirectStandardError $StdErrFilePath
            $rclonePID = $process.Id
            Write-Log -Level INFO -Message "Started rclone process with PID: $rclonePID" -LogFile $LogFile

            # Monitoring loop
            while (-not $process.HasExited) {
                Start-Sleep -Seconds $LogIntervalSeconds  # Sleep briefly to avoid busy-waiting

                # Calculate elapsed time and inactivity time
                $elapsedTime = (Get-Date) - $startTime
                $inactivityTime = (Get-Date) - $lastProgressTime

                # Simplified elapsed time logging
                Write-Log -Level DEBUG -Message "rclone is still running. Elapsed: $($elapsedTime.ToString('hh\:mm\:ss'))" -LogFile $LogFile

                # Check for inactivity
                if ($inactivityTime.TotalSeconds -ge $MaxInactivityTime) {
                    Write-Log -Level ERROR -Message "rclone process (PID: $rclonePID) has been inactive for $($inactivityTime.ToString('hh\:mm\:ss')). Terminating process." -LogFile $LogFile
                    $process.Kill()
                    throw "rclone process (PID: $rclonePID) terminated due to inactivity."
                }

                # Check if new log entries exist (update last progress time)
                if (Test-Path $RcloneLogFilePath) {
                    $newLogLines = Get-Content -Path $RcloneLogFilePath -Tail 10
                    if ($newLogLines.Count -gt 0) {
                        $lastProgressTime = Get-Date
                    }
                }
            }

            # Wait for the process to exit with a timeout
            if (-not $process.WaitForExit($WaitTimeoutMs)) {
                Write-Log -Level ERROR -Message "rclone process (PID: $rclonePID) did not exit within $($WaitTimeoutMs / 1000) seconds. Forcibly terminating." -LogFile $LogFile
                $process.Kill()
                $finalExitCode = -2  # Assign a distinct failure code for forced termination
            } else {
                # Capture the exit code properly
                $finalExitCode = $process.ExitCode
            }

            # Ensure exit code is properly captured
            if ($null -eq $finalExitCode) {
                Write-Log -Level ERROR -Message "rclone process (PID: $rclonePID) exited, but no exit code was captured!" -LogFile $LogFile
                $finalExitCode = -1  # Assign a failure code to avoid silent failures
            }

            Write-Log -Level INFO -Message "rclone process (PID: $rclonePID) exited with code $finalExitCode" -LogFile $LogFile

            # Read stdout content
            if (Test-Path $StdOutFilePath) {
                $stdoutContent = Get-Content -Path $StdOutFilePath -ErrorAction Stop
            }

            # Read stderr content and log if any errors exist
            if (Test-Path $StdErrFilePath) {
                $stderrContent = Get-Content -Path $StdErrFilePath -ErrorAction Ignore
                if ($stderrContent) {
                    Write-Log -Level ERROR -Message "rclone stderr output:`n$stderrContent" -LogFile $LogFile
                }
            }

            # Check if the process is still running even after exit signal
            $stillRunning = Get-Process -Id $rclonePID -ErrorAction SilentlyContinue
            if ($stillRunning) {
                Write-Log -Level ERROR -Message "rclone process (PID: $rclonePID) is still running despite exit signal! Something prevented its termination." -LogFile $LogFile
                $finalExitCode = -3  # Assign a specific failure code
            }

            # Look for Windows event logs related to rclone termination
            $eventLog = Get-WinEvent -LogName System -MaxEvents 10 | Where-Object { $_.Message -match "rclone.exe" }
            if ($eventLog) {
                Write-Log -Level ERROR -Message "Potential Windows termination event found for rclone: $($eventLog.Message)" -LogFile $LogFile
            }

            # Check the exit code to determine success or retry
            switch ($finalExitCode) {
                0 {
                    Write-Log -Level INFO -Message "rclone completed successfully (PID: $rclonePID)." -LogFile $LogFile
                    $commandSucceeded = $true
                }
                3 {
                    Write-Log -Level WARNING -Message "rclone completed with warnings (exit code 3). This may indicate skipped files or unchanged data." -LogFile $LogFile
                    $commandSucceeded = $true
                }
                default {
                    Write-Log -Level ERROR -Message "rclone command failed with exit code $finalExitCode (PID: $rclonePID)." -LogFile $LogFile
                    $commandSucceeded = $false
                }
            }

        } catch {
            $errorMessage = "Error running rclone command: $_"
            Write-Log -Level ERROR -Message $errorMessage -LogFile $LogFile
        } finally {
            # Ensure process cleanup
            if ($process -and -not $process.HasExited) {
                Write-Log -Level WARNING -Message "Cleaning up rclone process (PID: $rclonePID)" -LogFile $LogFile
                $process.Kill()
            }
        }

        $retryCount++

    } while (-not $commandSucceeded -and $retryCount -lt $MaxRetries)

    # Return the final result as an object, including stdout content
    return @{
        Succeeded = $commandSucceeded
        ExitCode = $finalExitCode
        StdOut = $stdoutContent
    }
}




function Start-RcloneJob {
    param (
        [string]$Command,
        [string]$Arguments,
        [string]$LogFile,
        [string]$OutputLogFile,        # Log file for real-time monitoring
        [int]$ProgressInterval = 15    # Default progress interval
    )

    # Start the rclone job in a background job
    $job = Start-Job -ScriptBlock {
        param ($scriptRoot, $command, $arguments, $logFile, $outputLogFile)

        # Load configuration and execute rclone
        . "$scriptRoot\initialize_cfg.ps1"
        $output = Execute-RcloneCommand -Command $command -Arguments $arguments -LogFile $logFile -RcloneLogFilePath $outputLogFile

        # Return rclone output
        return $output
    } -ArgumentList $PSScriptRoot, $Command, $Arguments, $LogFile, $OutputLogFile

    try {
        # Initialize loop counter and last read position for tracking new log content
        $loopCounter = 0
        $lastReadLineCount = 0  # This variable will track the last line position read from the log file

        # Monitor the job progress
        while ($job.State -eq "Running") {
            Start-Sleep -Seconds $ProgressInterval
            $loopCounter++
            Write-Log -Level INFO -Message "rclone process is still running (iteration $loopCounter). Waiting for completion..." -LogFile $LogFile

            # Capture only new lines from OutputLogFile for real-time monitoring
            if (Test-Path $OutputLogFile) {
                # Get total line count in the log file
                $totalLines = (Get-Content -Path $OutputLogFile).Count

                # Check if there are new lines
                if ($totalLines -gt $lastReadLineCount) {
                    # Read only new lines added since last read
                    $newLines = Get-Content -Path $OutputLogFile | Select-Object -Skip $lastReadLineCount
                    Write-Log -Level INFO -Message "Latest rclone log output: `n$($newLines -join "`n")" -LogFile $LogFile

                    # Update last read line count
                    $lastReadLineCount = $totalLines
                }
            }
        }

        # Once the job completes, retrieve the job output
        $jobOutput = Receive-Job -Job $job
        Write-Log -Level INFO -Message "rclone command completed." -LogFile $LogFile
        Write-Log -Level DEBUG -Message "rclone command output: `n$jobOutput" -LogFile $LogFile

        # Return the job output
        return $jobOutput

    } finally {
        # Ensure cleanup: Stop and remove the job if it's still running
        if ($job.State -eq "Running") {
            Write-Log -Level WARNING -Message "Stopping the rclone job manually." -LogFile $LogFile
            Stop-Job -Job $job -Force
        }

        # Remove the job (whether it was running or completed)
        Remove-Job -Job $job
        Write-Log -Level INFO -Message "rclone job has been removed." -LogFile $LogFile
    }
}
