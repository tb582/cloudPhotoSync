# userConfig.sample.ps1
# Copy this file to userConfig.ps1 and customise the paths to match your environment.

# Root directory where logs, metadata, and include files are stored
$syncRoot = "C:\\SyncHub"

# Files used across the sync workflow
$global:FilePathMD5Sum          = Join-Path $syncRoot 'md5.sum'
$global:FilePathLastRun         = Join-Path $syncRoot 'lastrun.txt'
# Rclone filter file that limits which remote objects are considered (see README).
$global:FilePathRemoteFilter    = Join-Path $syncRoot 'remote_filter.txt'
$global:FilePathLogRemoteListing = Join-Path $syncRoot 'log_remote_listing.txt'
$global:FilePathFilterFile      = Join-Path $syncRoot 'filter-file.txt'
$global:FilePathLogProdMD5      = Join-Path $syncRoot 'log_prod_md5.txt'
$global:FilePathSumErrors       = Join-Path $syncRoot 'sumerrors.txt'
$global:FilePathIncludeFile     = Join-Path $syncRoot 'includeFile.txt'
$global:FilePathLogProdCopy     = Join-Path $syncRoot 'log_prod_copy.txt'
$global:LogFile                 = Join-Path $syncRoot 'main_log.txt'
$global:ConsolidatedLogFile     = Join-Path $syncRoot 'consolidated_log.txt'
$global:LargeFileLog            = Join-Path $syncRoot 'large_debug_log.txt'
$Global:StdOutFilePath          = Join-Path $syncRoot 'rclone_stdout.txt'
$Global:StdErrFilePath          = Join-Path $syncRoot 'rclone_stderr.txt'

# Local destination for downloaded media
$global:DirectoryLocalPictures = "C:\\Users\\<username>\\Pictures"

# Windows Event Log configuration
$global:EventSource = "ps_syncNew"
$global:LogName     = "pcloud_rclone"

# Execution flags
$global:DryRun    = $true   # Default to dry-run for safety
$global:Bootstrap = $false  # Set $true to ignore previous run timestamps

# Create a timestamped file for dedupe logs at every run
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$global:FilePathLogDuplicates = Join-Path $syncRoot "log_duplicates_$timestamp.txt"

