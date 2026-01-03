# logging_cfg.ps1
# Set ErrorActionPreference to stop on errors
$ErrorActionPreference = "Stop"

# Function to validate if the log path exists and create it if necessary
function Validate-LogFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogFilePath
    )

    try {
        # Debugging: Display the log file path being validated

        # Extract directory from log file path
        $logDirectory = [System.IO.Path]::GetDirectoryName($LogFilePath)

        # Ensure the directory exists, create if necessary
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
        }

        # Ensure log file exists, create if necessary
        if (-not (Test-Path $LogFilePath)) {
            Write-Host "Creating log file: $LogFilePath"
            try {
                # Attempt to create the log file
                $null = "" | Out-File -FilePath $LogFilePath -Append -Encoding UTF8 -ErrorAction Stop
                Write-Host "Successfully created log file: $LogFilePath"
            } catch {
                # Log detailed error information
                Write-Host "Error creating log file: $($_.Exception.Message)"
                throw "Error: Failed to create log file: $LogFilePath. Error details: $($_.Exception.Message)"
            }
        } else {
            Write-Host "Log file already exists: $LogFilePath"
        }

    } catch {
        # Improved error handling with -f string formatting
        $errorMessage = "Error during log validation for {0}: {1}" -f $LogFilePath, $_.Exception.Message
        Write-Log -Level ERROR -Message $errorMessage
        throw ("Error: Failed to create log file or directory for {0}" -f $LogFilePath)
    }
}

# Function to validate all log paths dynamically loaded from userConfig.ps1
function Validate-AllLogFiles {
    try {
        # List of specific log files used across different scripts
        $LogFileVariables = @(
            $Global:LogFile,                    # Main log file
            $Global:LargeFileLog,               # Large untruncated entries
            $Global:ConsolidatedLogFile,        # Consolidated log file
            $Global:FilePathLogRemoteListing,    # Log for remote listing task
            $Global:FilePathLogProdMD5,         # Log for MD5 rclone output
            $Global:FilePathLogProdCopy         # Log for rclone copy command
        )

        foreach ($logFilePath in $LogFileVariables) {
            # Skip empty or null values to avoid errors
            if ([string]::IsNullOrWhiteSpace($logFilePath)) {
                continue
            }

            try {
                Validate-LogFile -LogFilePath $logFilePath
            } catch {
                Write-Host "Failed to validate path: $logFilePath. Error: $_"
                throw $_  # Re-throw the error to ensure script stops
            }
        }
    } catch {
        Write-Host "Error during log path validation: $_"
        throw $_  # Re-throw the error to ensure script stops
    }
}

# Function to write log entries
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "DEBUG", "ERROR", "WARNING")]
        [string]$Level = "INFO",
        [int]$EventID = 1,
        [string]$LogFile = $global:LogFile,
        [switch]$ConsoleOutput  # Optional: Show this log on the console
    )

    # Create the log entry format
    $logEntry = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss.fffff") [$Level] $Message"

    # Write to the primary log file
    try {
        Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    } catch {
        if ($ConsoleOutput) { Write-Host "Failed to write to log file: $_" }
    }

    # Conditionally log to the Windows Event Log (only in Windows PowerShell Desktop)
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        try {
            # Define the Event Log Entry Type
            $eventEntryType = switch ($Level) {
                "ERROR"   { "Error" }
                "WARNING" { "Warning" }
                "INFO"    { "Information" }
                default   { "Information" }
            }

            # Write to Event Log
            Write-EventLog -LogName $Global:LogName -Source $Global:EventSource -EventId $EventID -EntryType $eventEntryType -Message $Message
        } catch {
            # Log failure to write to Event Log
            $eventLogError = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss.fffff") [ERROR] Failed to write to Event Log: $_"
            Add-Content -Path $LogFile -Value $eventLogError -Encoding UTF8
            if ($ConsoleOutput) { Write-Host $eventLogError }
        }
    } elseif ($ConsoleOutput) {
        # Write to console if requested (and not using Windows Event Log)
        Write-Host $logEntry
    }
}

function Validate-LocalDestination {
    $localRoot = $Global:DirectoryLocalPictures
    if ([string]::IsNullOrWhiteSpace($localRoot)) {
        Write-Log -Level ERROR -Message "Local destination path is empty. Check DirectoryLocalPictures in your config."
        Exit 1
    }

    if (-not (Test-Path $localRoot)) {
        Write-Log -Level ERROR -Message "Local directory '$localRoot' not found. Aborting."
        Exit 1
    }
}

function Truncate-LogIfLarge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFilePath,
        [Parameter(Mandatory = $true)]
        [long]$MaxBytes
    )

    if (-not (Test-Path $LogFilePath)) { return }
    try {
        $fileInfo = Get-Item -Path $LogFilePath -ErrorAction Stop
        if ($fileInfo.Length -gt $MaxBytes) {
            Clear-Content -Path $LogFilePath -ErrorAction Stop
            Write-Log -Level WARNING -Message "Truncated log file $LogFilePath (was $($fileInfo.Length) bytes; max $MaxBytes)."
        }
    } catch {
        Write-Log -Level ERROR -Message "Failed to truncate log file ${LogFilePath}: $($_.Exception.Message)"
    }
}

function Truncate-LogsIfNeeded {
    if (-not $Global:LogMaxBytes) {
        $Global:LogMaxBytes = 50MB
    }

    $LogFileVariables = @(
        $Global:LogFile,
        $Global:LargeFileLog,
        $Global:ConsolidatedLogFile,
        $Global:FilePathLogRemoteListing,
        $Global:FilePathLogProdMD5,
        $Global:FilePathLogProdCopy,
        $Global:FilePathLogDuplicates,
        $Global:StdOutFilePath,
        $Global:StdErrFilePath
    )

    foreach ($logFilePath in $LogFileVariables) {
        if ([string]::IsNullOrWhiteSpace($logFilePath)) { continue }
        Truncate-LogIfLarge -LogFilePath $logFilePath -MaxBytes $Global:LogMaxBytes
    }
}


# Start by validating all necessary log paths
Validate-AllLogFiles
Truncate-LogsIfNeeded

