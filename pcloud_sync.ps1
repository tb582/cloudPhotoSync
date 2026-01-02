[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$RemoteName = 'remote',
    [switch]$DryRun,
    [switch]$LiveRun,
    [switch]$SkipProcessControl,
    [switch]$SkipDedupe,
    [string]$DedupePath,
    [switch]$IgnoreMaxAge,
    [switch]$FailOnRcloneError
)

if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    try {
        $resolvedPathInfo = Resolve-Path -Path $ConfigPath -ErrorAction Stop | Select-Object -First 1
        $env:PCLOUDSYNC_CONFIG = $resolvedPathInfo.Path
    } catch {
        throw "Unable to resolve configuration path '$ConfigPath': $($_.Exception.Message)"
    }
}

. "$PSScriptRoot\initialize_cfg.ps1"

$ErrorActionPreference = "Stop"

if ($DryRun -and $LiveRun) {
    throw "Specify only one of -DryRun or -LiveRun."
}

if ($DryRun) {
    $Global:DryRun = $true
}

if ($LiveRun) {
    $Global:DryRun = $false
}

$remoteNameNormalized = if ($RemoteName.EndsWith(':')) { $RemoteName } else { "${RemoteName}:" }
$remoteRootPath = "$remoteNameNormalized/"

Write-Log -Level INFO -Message "Using remote $remoteNameNormalized"

Write-Log -Level INFO -Message "`n`n`nStarting ps_syncNew via rclone and PowerShell"

# Initialize configuration
Initialize-Configuration

# Allow test runs to bypass the max-age filter.
if ($IgnoreMaxAge) {
    $Global:MaxAgeFlag = ''
    Write-Log -Level INFO -Message "IgnoreMaxAge specified: disabling max-age filtering for this run."
}

# Ensure rclone is available before starting any sync operations
$rcloneCommand = Get-Command rclone -ErrorAction SilentlyContinue
if (-not $rcloneCommand) {
    $message = 'rclone executable not found on PATH. Install rclone or add it to PATH before running.'
    Write-Log -Level ERROR -Message $message
    throw $message
}

# Stop Google Drive File Stream (GDFS) if needed
if ($SkipProcessControl) {
    Write-Log -Level INFO -Message "SkipProcessControl specified: not stopping GoogleDriveFS."
} else {
    Stop-GoogleDriveFS
}

# Log and output global variables for debugging purposes
Write-Host "MaxAgeFlag: $Global:MaxAgeFlag"

# Validate the existence of the MD5 sum file path
$filePath = $Global:FilePathMD5Sum
if (Test-Path $filePath) {
    # Import MD5 sums from CSV and store in a variable
    $localmd5 = Import-CSV -Delimiter " " -Path $filePath | Select-Object -ExpandProperty MD5
    Write-Log -Level INFO -EventID 3 -Message "Stored local md5s in variable"
} else {
    # Log an error and exit the script if the MD5 file is missing
    Write-Log -Level ERROR -EventID 3 -Message "$($filePath) doesn't exist"
    Exit 1  # Exit script with a failure code since $filePath doesn't exist
}

# Add dry-run flag for rclone if DryRun is enabled
$dryRunFlag = if ($Global:DryRun) { "--dry-run" } else { "" }

# Notify that dry-run mode is active
if ($Global:DryRun) {
    Write-Log -Level INFO -Message "Dry-run mode is active. No changes will be made to the filesystem."
}

# Scope filter files when a dedupe path is provided (useful for small test runs)
$effectiveRemoteFilter = $Global:FilePathRemoteFilter
$effectiveHashFilter = $Global:FilePathFilterFile
if (-not [string]::IsNullOrWhiteSpace($DedupePath)) {
    $scopePath = $DedupePath.Trim()
    if ($scopePath.StartsWith($remoteNameNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        $scopePath = $scopePath.Substring($remoteNameNormalized.Length)
    }
    $scopePath = $scopePath.TrimStart('/', '\').Replace('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($scopePath)) {
        $tempRoot = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
        $scopeFilterPath = Join-Path $tempRoot ("pcloud_scope_filter_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        @(
            "# Scoped filter for $scopePath",
            "+ /$scopePath",
            "+ /$scopePath/**",
            "- *"
        ) | Set-Content -Path $scopeFilterPath -Encoding UTF8
        $effectiveRemoteFilter = $scopeFilterPath
        $effectiveHashFilter = $scopeFilterPath
        Write-Log -Level INFO -Message "Scoping remote filters to /$scopePath using $scopeFilterPath."
    } else {
        Write-Log -Level WARNING -Message "DedupePath was provided but resolved to an empty scope; using configured filters."
    }
}

# Log that the rclone command is starting for the specified file
Write-Log -Level DEBUG -EventID 4 -Message "Running rclone command against $effectiveRemoteFilter"

# Define parameters for rclone command
$command = "ls"
$arguments = "$remoteRootPath --filter-from $effectiveRemoteFilter $global:MaxAgeFlag $dryRunFlag"
$logFile = $Global:LogFile
$rcloneLogFilePath = $Global:FilePathLogRemoteListing
$progressInterval = 15
$maxRetries = 3
# Log Elapsed Time
$startTime = Get-Date
# Call Execute-RcloneCommand and handle result
$rcloneResult = Execute-RcloneCommand -Command $command -Arguments $arguments -LogFile $logFile -RcloneLogFilePath $rcloneLogFilePath -ProgressInterval $progressInterval -MaxRetries $maxRetries

if ($rcloneResult.Succeeded) {
    Write-Log -Level INFO -Message "rclone command completed successfully."

    # The final log file output is already captured in Execute-RcloneCommand if needed
} else {
    Write-Log -Level ERROR -Message "rclone command failed after $maxRetries attempts. Exit Code: $($rcloneResult.ExitCode)"
    if ($FailOnRcloneError) {
        throw "rclone ls failed after $maxRetries attempts. Exit Code: $($rcloneResult.ExitCode)"
    }
}
$endTime = Get-Date
$elapsedTime = $endTime - $startTime
# Optional: Sleep briefly to ensure rclone output is fully flushed
Start-Sleep -Milliseconds 500
Write-Log -Level INFO -Message "step1 remote LS completed in $($elapsedTime.TotalSeconds) seconds."
# Ensure $stdoutFilePath is defined and valid before proceeding
$stdoutFilePath = $Global:StdOutFilePath
if (Test-Path $stdoutFilePath) {
    # Attempt to read the file with StreamReader line-by-line into an array
    try {
        $reader = [System.IO.StreamReader]::new($stdoutFilePath, [System.Text.Encoding]::UTF8)
        $remoteListing = @()  # Initialize $remoteListing as an empty array

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $remoteListing += $line  # Append each line to the $remoteListing array
        }
        $reader.Close()

        # Log the first 5 lines for debugging
        if ($remoteListing.Count -gt 0) {
            $firstFiveLines = $remoteListing | Select-Object -First 5
            Write-Log -Level INFO -Message "Successfully read remote listing output. Sample content (first 5 lines): `n$($firstFiveLines -join "`n")"
        } else {
            Write-Log -Level WARNING -Message "rclone stdout file exists but is empty or whitespace only."
        }
    } catch {
        Write-Log -Level ERROR -Message "Error reading rclone stdout file with StreamReader: $_"
    }
} else {
    $remoteListing = @()  # Set $remoteListing as an empty array
    Write-Log -Level WARNING -Message "Expected rclone stdout file '$stdoutFilePath' not found."
}
Write-Log "End of special file handling moving to check for duplicates"
## End of special handling 

## Deduplication process on the remote files
if ($SkipDedupe) {
    Write-Log -Level INFO -Message "SkipDedupe specified: skipping deduplication step."
} else {
    # Deduplication step
    $dedupeTarget = $remoteNameNormalized
    if (-not [string]::IsNullOrWhiteSpace($DedupePath)) {
        $trimmedPath = $DedupePath.Trim()
        if ($trimmedPath.StartsWith($remoteNameNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
            $dedupeTarget = $trimmedPath
        } else {
            $trimmedPath = $trimmedPath.TrimStart('/', '\')
            $dedupeTarget = "$remoteNameNormalized$trimmedPath"
        }
    }

    Write-Log -Level INFO -Message "Starting deduplication process on $dedupeTarget..."

    # Define deduplication parameters
    $dedupeCommand = "dedupe"
    $dedupeTargetQuoted = '"' + $dedupeTarget + '"'
    $dedupeFilterPath = $null
    if (-not [string]::IsNullOrWhiteSpace($DedupePath) -and $effectiveRemoteFilter -and (Test-Path $effectiveRemoteFilter)) {
        $dedupeFilterPath = $effectiveRemoteFilter
    } elseif ($Global:FilePathDedupeFilter -and (Test-Path $Global:FilePathDedupeFilter)) {
        $dedupeFilterPath = $Global:FilePathDedupeFilter
    } elseif ($effectiveRemoteFilter -and (Test-Path $effectiveRemoteFilter)) {
        $dedupeFilterPath = $effectiveRemoteFilter
    }
    $dedupeFilterArg = if ($dedupeFilterPath) { "--filter-from $dedupeFilterPath" } else { "" }
    $dedupeArguments = "--by-hash --dedupe-mode newest $dedupeTargetQuoted $dedupeFilterArg $dryRunFlag $global:MaxAgeFlag"
    $dedupeLogFile = $Global:FilePathLogDuplicates
    $progressInterval = 15
    $maxRetries = 3

    # Log Elapsed Time
    $startTime = Get-Date

    # Run the deduplication task using Execute-RcloneCommand
    $dedupeResult = Execute-RcloneCommand -Command $dedupeCommand -Arguments $dedupeArguments -LogFile $Global:LogFile -RcloneLogFilePath $dedupeLogFile -ProgressInterval $progressInterval -MaxRetries $maxRetries

    $endTime = Get-Date
    $elapsedTime = $endTime - $startTime
    Write-Log -Level INFO -Message "Deduplication process completed in $($elapsedTime.TotalSeconds) seconds."

    # Check if the rclone task succeeded 

    # $dedupeResult = @{ # Simulating success for testing
    #    Succeeded = $true  # Simulating success for testing
    # }# Simulating success for testing

    if ($dedupeResult.Succeeded) {
        # Parse the deduplication log file to analyze duplicates # Simulating success for testing
    #    $dedupeLogFile = "P:\scripts\log_duplicates_20241115_204255.txt" # Simulating success for testing

        if (Test-Path $dedupeLogFile) {
            try {
                # Initialize counters
                $totalDuplicateFiles = 0
                $totalStorageSavedBytes = 0

                # Regex patterns
                $duplicatePattern = "Found (\d+) files with duplicate md5 hashes"
                $sizePattern = "Skipped delete as --dry-run is set \(size ([\d\.]+)([KMGT]i)?\)"

                # Process duplicate counts
                $duplicateMatches = Select-String -Path $dedupeLogFile -Pattern $duplicatePattern
                if ($duplicateMatches) {
                    $totalDuplicateFiles = $duplicateMatches |
                        ForEach-Object {
                            # Extract the number of duplicates and subtract 1 (n - 1 files deleted)
                            [int]$_.Matches[0].Groups[1].Value - 1
                        } |
                        Measure-Object -Sum | Select-Object -ExpandProperty Sum
                }

                # Process skipped file sizes
                if ($Global:DryRun) {
                    $sizeMatches = Select-String -Path $dedupeLogFile -Pattern $sizePattern
                    if ($sizeMatches) {
                        $totalStorageSavedBytes = $sizeMatches |
                            ForEach-Object {
                                # Extract the size and unit (e.g., Ki, Mi, Gi, Ti)
                                $sizeValue = [float]$_.Matches[0].Groups[1].Value
                                $sizeUnit = $_.Matches[0].Groups[2].Value

                                # Convert sizes to bytes based on unit
                                switch ($sizeUnit) {
                                    "Ki" { $sizeValue * 1024 }
                                    "Mi" { $sizeValue * 1024 * 1024 }
                                    "Gi" { $sizeValue * 1024 * 1024 * 1024 }
                                    "Ti" { $sizeValue * 1024 * 1024 * 1024 * 1024 }
                                    default { $sizeValue }  # Bytes (no unit)
                                }
                            } |
                            Measure-Object -Sum | Select-Object -ExpandProperty Sum
                    } else {
                        Write-Log -Level WARNING -Message "No size information found in deduplication log. This may occur if no deletions were skipped."
                        $totalStorageSavedBytes = 0
                    }
                } else {
                    Write-Log -Level INFO -Message "Skipping size calculation as this is not a dry-run. Size information is not logged by rclone when --dry-run is not set."
                    $totalStorageSavedBytes = 0
                }

                # Log results
                if ($totalDuplicateFiles -gt 0) {
                    Write-Log -Level INFO -Message "Deduplication completed: $totalDuplicateFiles duplicate files identified for removal."

                    # Convert total saved bytes to a human-readable format
                    if ($Global:DryRun) {
                        $totalSaved = if ($totalStorageSavedBytes -ge 1024 * 1024 * 1024) {
                            "{0:N2} GiB" -f ($totalStorageSavedBytes / (1024 * 1024 * 1024))
                        } elseif ($totalStorageSavedBytes -ge 1024 * 1024) {
                            "{0:N2} MiB" -f ($totalStorageSavedBytes / (1024 * 1024))
                        } elseif ($totalStorageSavedBytes -ge 1024) {
                            "{0:N2} KiB" -f ($totalStorageSavedBytes / 1024)
                        } else {
                            "{0:N2} Bytes" -f $totalStorageSavedBytes
                        }
                    }
                    if ($Global:DryRun) {
                        Write-Log -Level INFO -Message "Dry-run mode: Estimated storage savings: $totalSaved."
                    } else {
                        Write-Log -Level INFO -Message "Storage savings: $totalSaved after removing duplicates."
                    }
                } else {
                    Write-Log -Level INFO -Message "No duplicates were found or deduplication was already completed."
                }

            } catch {
                # Handle errors in parsing or processing the log
                Write-Log -Level ERROR -Message "Error parsing deduplication log file '$dedupeLogFile': $_"
            }
        } else {
            # Handle case where the deduplication log file is missing
            Write-Log -Level ERROR -Message "Deduplication log file '$dedupeLogFile' not found. Cannot process duplicate counts."
        }
    } else {
        # Handle rclone deduplication task failure
        Write-Log -Level ERROR -Message "Deduplication process failed. Check logs for details."
        if ($FailOnRcloneError) {
            throw "rclone dedupe failed. Exit Code: $($dedupeResult.ExitCode)"
        }
        Exit 1  # Exit the script with a failure code
    }

    Write-Log -Level INFO -Message "Deduplication process completed." 
}

# ---------------------------------------
# Step: Generate and Validate Remote Hash Sums
# ---------------------------------------
Write-Log -Level INFO -Message "Starting rclone hashsum operation for $remoteNameNormalized (MD5 checksum comparison)."

# Define rclone hashsum parameters
$hashCommand = "hashsum"
$hashArguments = "MD5 $remoteNameNormalized $dryRunFlag $Global:MaxAgeFlag --filter-from $effectiveHashFilter"

# Execute the hashsum command
Write-Log -Level DEBUG -Message "Running rclone hashsum with arguments: rclone $hashArguments"

try {
    # Execute the rclone hashsum command
    # Log Elapsed Time
    $startTime = Get-Date
    $result = Execute-RcloneCommand -Command $hashCommand -Arguments $hashArguments -RcloneLogFilePath $Global:FilePathLogProdMD5

    # Ensure the command succeeded
    if (-not $result.Succeeded) {
        Write-Log -Level ERROR -EventID 101 -Message "Rclone hashsum did not complete successfully. Exit code: $($result.ExitCode)."
        if ($FailOnRcloneError) {
            throw "rclone hashsum failed. Exit Code: $($result.ExitCode)"
        }
        Exit 1
    }
    $endTime = Get-Date
    $elapsedTime = $endTime - $startTime
    # Process stdout content to extract file information
    $remoteFiles = $result.StdOut | Where-Object { $_ -match "^[a-f0-9]{32}" }  # Filter lines with MD5 hashes

    # Validate that files were found
    if (-not $remoteFiles -or $remoteFiles.Count -eq 0) {
        Write-Log -Level ERROR -EventID 101 -Message "Rclone hashsum did not return any valid results. Check the logs and remote configuration."
        Exit 1
    }
    Write-Log -Level INFO -Message "Rclone hashsum operation completed successfully in $($elapsedTime.TotalSeconds) seconds.`nFound $($remoteFiles.Count) new file(s)."
} catch {
    # Handle any unexpected errors during command execution or result processing
    Write-Log -Level ERROR -EventID 102 -Message "An error occurred while executing rclone hashsum: $($_.Exception.Message)"
    Exit 1
}
# $remoteFiles = Get-Content -Path "P:\scripts\rclone_stdout.txt" # testing simulation

# Extract valid MD5 lines and transform to key=value format
$remoteFileHashEntries = $remoteFiles |
    Where-Object { -not ($_ | Select-String -Quiet -NotMatch -Pattern '^[a-f0-9]{32}(  )') } | # Filter valid MD5 lines
    ForEach-Object {
        # Extract MD5 hash (key) and file path (value)
        if ($_ -match '^(?<MD5>[a-f0-9]{32})\s{2}(?<FilePath>.+)$') {
            "$($matches['MD5'])=$($matches['FilePath'])"
        }
    }

# Identify duplicates
$duplicateKeys = $remoteFileHashEntries |
    ForEach-Object {
        ($_ -split '=')[0]  # Extract just the MD5 key
    } |
    Group-Object | Where-Object { $_.Count -gt 1 } |
    Select-Object -ExpandProperty Name

# Log invalid hash lines (if any)
$invalidHashLines = $remoteFiles | Where-Object { $_ | Select-String -Quiet -NotMatch -Pattern '^[a-f0-9]{32}(  )' }
if ($invalidHashLines.Count -gt 0) {
    Write-Log -Level WARNING -Message "Found $($invalidHashLines.Count) paths without valid checksums."
    $invalidHashLines | Out-File $Global:FilePathSumErrors -Append
} else {
    Write-Log -Level DEBUG -Message "Did not find any paths without valid checksums; continuing"
}

# If duplicates are found, log and exit (unless dedupe is skipped)
if ($duplicateKeys.Count -gt 0) {
    if ($SkipDedupe) {
        Write-Log -Level WARNING -Message "Duplicate MD5 hashes detected ($($duplicateKeys.Count)), but SkipDedupe is set. Skipping duplicate enforcement."
    } else {
        Write-Log -Level ERROR -Message "Duplicate MD5 hashes detected at this stage: $($duplicateKeys.Count)"
        Write-Log -Level ERROR -Message "This indicates the deduplication step did not complete successfully. Exiting script."
        Exit 1
    }
}

# Convert the cleaned list to a hashtable
$remoteFileHash = $remoteFileHashEntries -join "`n" | ConvertFrom-StringData

# Log success
Write-Log -Level INFO -Message "Successfully converted remote file hash data to a hashtable with $($remoteFileHash.Count) entries."

# ---------------------------------------
# Step: Compare Remote Hash Sums Against Local
# ---------------------------------------

Write-Log -Level INFO -Message "Starting comparison of remote hash sums against local."

# Create a hash set from the local hashes (assumed loaded earlier into $localmd5)
$localHashSet = [System.Collections.Generic.HashSet[string]]::new()
$localmd5 | ForEach-Object { [void]$localHashSet.Add($_) }

# Compare remote hashes against local hashes
$diffmd5 = $remoteFileHash.GetEnumerator().Where({ -not $localHashSet.Contains($_.Key) })

# Count differences
$diffCount = $diffmd5.Count

# Count matches
$matchCount = $remoteFileHash.Count - $diffCount

# Log details about the comparison
Write-Log -Level INFO -Message "Remote hashes matching local hashes: $($matchCount)."
Write-Log -Level INFO -Message "Remote hashes not found locally (files to be copied): $($diffCount)."

# Log additional debugging details if there's a significant mismatch
if ($matchCount + $diffCount -ne $remoteFileHash.Count) {
    Write-Log -Level WARNING -Message "Discrepancy detected in hash comparison. Mismatch between remote hash count and the sum of matches and differences."
    Write-Log -Level WARNING -Message "This may indicate duplicate keys in the remote or an error in processing."
}

# Log files that are missing locally (only if debugging is enabled)
if ($diffCount -gt 0) {
    Write-Log -Level DEBUG -Message "Listing files not found locally (first 5 for debugging):"
    $diffmd5.GetEnumerator() | Select-Object -First 5 | ForEach-Object {
        Write-Log -Level DEBUG -Message "Missing file: $($_.Value)"
    }
}

# Log summary of comparison
if ($diffCount -gt 0) {
    Write-Log -Level INFO -Message "Found $($diffCount) file(s) that need to be copied."
    # Write the list of files to an include file for rclone sync
    $diffmd5.Value | Out-File -FilePath $Global:FilePathIncludeFile -Encoding UTF8
    Write-Log -Level INFO -Message "Wrote file paths for $($diffCount) file(s) to include file: $Global:FilePathIncludeFile"
} else {
    Write-Log -Level INFO -Message "No differences found. All files are already synced."
}

# ---------------------------------------
# Step: File Synchronization with Retry Logic
# ---------------------------------------

if ($diffCount -gt 0) {
    Write-Log -Level INFO -Message "Starting file synchronization process for $($diffCount) file(s)."

    # Write file paths to include file for reference
    if ($Global:DryRun) {
        Write-Log -Level INFO -Message "Dry-run mode: Simulating include file generation. File paths will not actually be copied."
    }
    $diffmd5.Value | Out-File -FilePath $Global:FilePathIncludeFile -Encoding UTF8
    Write-Log -Level INFO -Message "Wrote file paths for $($diffCount) file(s) to include file: $Global:FilePathIncludeFile"

    # Initialize loop counter and start time
    $loopCounter = 0
    $startTime = Get-Date

    # Define maximum retry attempts
    $maxRetries = 3
    $failedFiles = @()  # To track failed files

    # Loop through files that need to be synced
    foreach ($path in $diffmd5.Value) {
        # Increment loop counter
        $loopCounter++

        $retryCount = 0
        $success = $false  # Track success for the current file

        do {
            try {
                # Perform file copy operation (or simulate if in dry-run mode)
                if (-not $Global:DryRun) {
                    Write-Log -Level INFO -Message "Initiating rclone copy for file: $path (iteration: $loopCounter, attempt: $($retryCount + 1))."
                    $result = Execute-RcloneCommand -Command "copy" -Arguments "$remoteNameNormalized""$path"" $Global:DirectoryLocalPictures --no-traverse --progress" -RcloneLogFilePath $Global:FilePathLogProdCopy

                    if ($result.Succeeded) {
                        Write-Log -Level INFO -Message "Successfully copied file: $path."
                        $success = $true
                    } else {
                        Write-Log -Level WARNING -Message "File copy failed for file: $path. Exit Code: $($result.ExitCode). Retrying..."
                        if ($FailOnRcloneError) {
                            throw "rclone copy failed for file: $path. Exit Code: $($result.ExitCode)"
                        }
                    }
                } else {
                    Write-Log -Level INFO -Message "Dry-run mode: Simulating file copy of $path to $Global:DirectoryLocalPictures."
                    $success = $true  # Assume success in dry-run mode
                }
            } catch {
                Write-Log -Level ERROR -Message "Error during file copy for file: $path. Error: $($_.Exception.Message)"
            }

            # Increment retry counter
            $retryCount++

            # If the max retries are reached and the copy still failed, log it
            if (-not $success -and $retryCount -ge $maxRetries) {
                Write-Log -Level ERROR -Message "Max retries ($maxRetries) reached for file: $path. Moving to next file."
                $failedFiles += $path  # Add file to the failed list
            }
        } while (-not $success -and $retryCount -lt $maxRetries)
    }

    # Calculate elapsed time
    $endTime = Get-Date
    $elapsedTime = $endTime - $startTime
    $filesPerSecond = if ($elapsedTime.TotalSeconds -gt 0) { $diffCount / $elapsedTime.TotalSeconds } else { 0 }

    # Log completion details
    Write-Log -Level INFO -Message "File synchronization process completed in $($elapsedTime.TotalSeconds) seconds ($filesPerSecond files/second)."

    # Check for failed files
    if ($failedFiles.Count -gt 0) {
        Write-Log -Level ERROR -Message "File synchronization completed with $($failedFiles.Count) failed file(s):"
        $failedFiles | ForEach-Object { Write-Log -Level ERROR -Message " - $_" }
    } else {
        Write-Log -Level INFO -Message "All files were successfully copied."
    }
} else {
    Write-Log -Level INFO -Message "No differences found. All files are already synced. Skipping synchronization step."
}


# Ensure local files are processed correctly
$localRoot = $Global:DirectoryLocalPictures
if (-not (Test-Path $localRoot)) {
    if ($Global:DryRun) {
        Write-Log -Level WARNING -Message "Local directory '$localRoot' not found. Skipping local file scan for dry-run."
        $localFiles = @()
        $localCount = 0
    } else {
        Write-Log -Level ERROR -Message "Local directory '$localRoot' not found. Aborting."
        Exit 1
    }
} else {
    # Normalize the local user profile path so hashes store portable paths
    $userProfileNormalized = ''
    if ($env:USERPROFILE) {
        $normalizedProfile = $env:USERPROFILE.TrimEnd([char]92, '/')
        if ($normalizedProfile) {
            $userProfileNormalized = ($normalizedProfile + '/').Replace([char]92, '/')
        }
    }
    $localFiles = Get-ChildItem $localRoot -Recurse -File |
        Get-FileHash -Algorithm MD5 | ForEach-Object {
            $normalizedPath = $_.Path.Replace([char]92, '/')
            if ($userProfileNormalized) {
                $normalizedPath = $normalizedPath.Replace($userProfileNormalized, '$HOME/')
            }
            '{0}  {1}' -f $_.Hash.ToLower(), $normalizedPath
        }

    $localCount = $localFiles | Measure-Object | Select-Object -expand Count
}

if ($localCount -ge $diffCount) {
    Write-Log -Level INFO -EventID 555 -Message "All files copied to local - preparing to update MD5 sum CSV."
    
    if (-not $Global:DryRun) {
        # Actual update of MD5 sum CSV file
        Write-Log -Level INFO -EventID 8 -Message "Writing to MD5 sum CSV file: $Global:FilePathMD5Sum"
        $localFiles | Out-File $Global:FilePathMD5Sum -Encoding UTF8 -Append

        # Actual writing of the last run date
        Write-Log -Level INFO -EventID 8 -Message "Writing the last run date to $Global:FilePathLastRun"
        Get-Date (Get-Date).AddDays(-1) -format "yyyy-MM-dd" | Out-File $Global:FilePathLastRun
    } else {
        # Dry-run: Simulate updating CSV and writing the date
        Write-Log -Level INFO -EventID 7 -Message "Dry-run mode: Simulating CSV update for MD5 sum."
        Write-Log -Level INFO -EventID 7 -Message "Dry-run mode: Simulating writing the last run date to $Global:FilePathLastRun"
    }
    
    # Completion message
    Write-Log -Level INFO -EventID 9 -Message "Completed."
} else {
    if (-not $Global:DryRun) {
        # Actual update of MD5 sum CSV file if not in dry-run mode
        Write-Log -Level INFO -EventID 8 -Message "Writing to MD5 sum CSV file: $Global:FilePathMD5Sum"
        $localFiles | Out-File $Global:FilePathMD5Sum -Encoding UTF8 -Append
    } else {
        # Dry-run: Simulate updating CSV file
        Write-Log -Level INFO -EventID 7 -Message "Dry-run mode: Simulating CSV update for MD5 sum (files not copied as expected)."
    }

    # Log the issue with file counts
    Write-Log -Level INFO -EventID 99 -Message "Local files do not match expected count! Not everything was copied. Last run date will not be updated."
    Write-Log -Level INFO -EventID 9 -Message "Completed - but not all files were counted - will leave settings for next run."
}


Write-Log -Level INFO -EventID 9 -Message "starting back up google drive process"
if ($SkipProcessControl) {
    Write-Log -Level INFO -Message "SkipProcessControl specified: not starting GoogleDriveFS."
} else {
    Start-GoogleDriveFS
}
if (-not $Global:DryRun) {
    Clear-Content $Global:FilePathIncludeFile
    Write-Log -Level INFO -EventID 9 -Message "removing entries from includesFile"
}
else {
    Write-Log -Level INFO -EventID 7 -Message "Dry-run mode: Simulating clearing include file"
}
Exit 0



