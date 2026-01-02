# pcloudRclone Sync

PowerShell automation that coordinates rclone with Google Drive File Stream to keep a pCloud remote in sync with a local photo library. The script performs:

- Remote listing and deduplication of files via rclone
- MD5 hashsum comparison against local state
- Optional rclone copy operations for new/changed files
- Graceful stop/start of Google Drive File Stream while the sync runs
- Detailed logging to text files and the Windows Event Log

## Prerequisites

- **Windows PowerShell 5.1 or PowerShell 7+**
- **[rclone](https://rclone.org/downloads/)** installed and configured with a remote (defaults expect it to be called `remote:`)
- **Google Drive for desktop** (optional; provides the `GoogleDriveFS` process the script pauses)
- Permission to create/write log files under the configured directory

## Getting Started

1. Clone this repository.
2. Copy `userConfig.sample.ps1` to `userConfig.ps1`.
3. Edit `userConfig.ps1` and update:
   - `$syncRoot` and all derived log/output paths
   - `$global:FilePathRemoteFilter` (rclone filter file that scopes which remote folders to process)
   - `$global:FilePathDedupeFilter` (optional filter file for dedupe-only exclusions)
   - `$global:DirectoryLocalPictures` (local destination for synced media)
   - Optional flags such as `$global:DryRun` and `$global:Bootstrap`
4. Ensure your rclone remote (`remote:` by default) points at the desired source.
5. Run the sync in **dry-run mode** first (see below) to verify paths and permissions.

## Configuration Wizard

Run the interactive wizard to capture your paths and options:

```powershell
pwsh -File .\Start-SyncWizard.ps1
```

- The wizard pre-fills values from `userConfig.sample.ps1` and your last saved answers.
- When you finish, the tool writes `userConfig.ps1` (or a custom path) and can optionally launch `pcloud_sync.ps1`.
- You can rerun the wizard any time to update paths or switch between dry-run/live defaults.

## Running the Sync

```powershell
pwsh -File .\pcloud_sync.ps1
```

- When `$global:DryRun` is `$true`, rclone commands are executed with `--dry-run` and copy operations are simulated. This is the safest way to validate your configuration.
- Set `$global:DryRun = $false` for a live run once you are satisfied with the output.
- The script automatically stops the `GoogleDriveFS` process at the start and restarts it when finished.

## Command-Line Parameters

- `-ConfigPath <path>`: Override the path to `userConfig.ps1`. Relative paths are resolved before the script loads configuration.
- `-RemoteName <name>`: Target rclone remote (with or without a trailing colon).
- `-DryRun`: Force dry-run regardless of the configuration file.
- `-LiveRun`: Force a live run even if the configuration file enables dry-run.
- `-SkipProcessControl`: Skip stopping and starting Google Drive File Stream — handy for automated tests.
- `-SkipDedupe`: Skip the deduplication step (useful for quick smoke tests).
- `-DedupePath <path>`: Run dedupe against a specific remote subpath and scope listing/hashsum to the same path (handy for testing small folders with spaces).
- `-IgnoreMaxAge`: Disable the max-age filter for the current run (handy for dry-run tests).
- `-FailOnRcloneError`: Throw on rclone failures instead of logging and continuing.

## Logs and Output

- The log destinations are defined in `userConfig.ps1`. By default they write under the directory referenced by `$syncRoot`.
- Each run produces a timestamped dedupe log and appends to the main log.
- Logs are truncated at startup when they exceed `$Global:LogMaxBytes` (defaults to 50MB; override in `userConfig.ps1`).
- Windows Event Log entries are written under the log name specified by `$global:LogName` (defaults to `pcloud_rclone`).

## Dedupe Filtering

If you want dedupe to skip noisy folders (for example `.git` or `venv`), create a dedupe filter file and set `$global:FilePathDedupeFilter` in `userConfig.ps1`. This filter is used only by the dedupe step and does not affect listing or hashsum.

Example `dedupe_filter.txt`:

```text
- /.git/**
- /.git_backup/**
- /venv/**
- /__pycache__/**
- /node_modules/**
- /System Volume Information/**
```

## Tests

Run `pwsh -File tests\Invoke-DryRun.ps1` to execute a guarded dry run. The helper exits early if `userConfig.ps1` is missing and always passes `-SkipProcessControl` so Google Drive File Stream stays untouched.

Example with scoped dedupe:

```powershell
pwsh -File tests\Invoke-DryRun.ps1 -DedupePath "My Pictures/Tests"
```

## Troubleshooting

- If you see `Configuration file '<path>' not found`, make sure you created `userConfig.ps1` from the provided sample.
- Run with `$global:DryRun = $true` to collect diagnostic logs without modifying the remote or local filesystem.
- Review the generated log files for verbose rclone output and elapsed time information.
- In dry-run mode, the local scan is skipped if the configured local directory does not exist; live runs still fail fast.

## Contributing

Contributions and bug reports are welcome! Please open an issue or submit a pull request. Running the sync in dry-run mode is a good sanity check before proposing changes.

## Before Publishing

Before publishing this repository, audit your Git history for secrets, personal data, or log snippets and rewrite/squash as needed. Keep `userConfig.ps1` out of version control.
## License

Licensed under the [MIT License](LICENSE).
