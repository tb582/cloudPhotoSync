if ($PSVersionTable.PSEdition -ne 'Desktop' -and $IsWindows -ne $true) {
    throw 'Sync wizard requires Windows.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Resolve-PowerShellHost {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    $ps = Get-Command powershell -ErrorAction SilentlyContinue
    if ($ps) { return $ps.Source }
    return $null
}

function ConvertTo-PsStringLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return "''" }
    $escaped = $Value -replace "'", "''"
    return "'$escaped'"
}

function Get-RelativePath {
    param([string]$BasePath, [string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($BasePath) -or [string]::IsNullOrWhiteSpace($TargetPath)) { return $null }
    try {
        $baseFull = [System.IO.Path]::GetFullPath($BasePath)
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
        if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $baseFull += [System.IO.Path]::DirectorySeparatorChar
        }
        $baseUri = [System.Uri]::new($baseFull)
        $targetUri = [System.Uri]::new($targetFull)
        if (-not $baseUri.IsBaseOf($targetUri)) { return $null }
        return $baseUri.MakeRelativeUri($targetUri).ToString().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    } catch {
        return $null
    }
}

function Get-WizardCachePath {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    return Join-Path $appData 'pcloudRcloneSync\wizard_state.json'
}

function Load-WizardStateCache {
    $path = Get-WizardCachePath
    if (-not (Test-Path $path)) { return $null }
    try {
        $json = Get-Content -Path $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Save-WizardStateCache {
    param([pscustomobject]$State)
    $path = Get-WizardCachePath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
    $payload = [pscustomobject]@{
        SyncRoot = $State.SyncRoot
        DirectoryLocalPictures = $State.DirectoryLocalPictures
        RemoteFilterPath = $State.RemoteFilterPath
        RemoteName = $State.RemoteName
        DryRun = $State.DryRun
        Bootstrap = $State.Bootstrap
        ConfigOutputPath = $State.ConfigOutputPath
        RunSyncAfter = $State.RunSyncAfter
    }
    $payload | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
}

function Read-ConfigSnapshot {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Configuration file '$Path' was not found." }
    $escaped = $Path -replace "'", "''"
    $script = @"
. '$escaped'
[PSCustomObject]@{
    SyncRoot = `$syncRoot
    DirectoryLocalPictures = `$global:DirectoryLocalPictures
    RemoteFilterPath = `$global:FilePathRemoteFilter
    DryRun = `$global:DryRun
    Bootstrap = `$global:Bootstrap
}
"@
    $ps = [PowerShell]::Create()
    try {
        $ps.AddScript($script) | Out-Null
        $result = $ps.Invoke()
        if ($ps.Streams.Error.Count -gt 0) {
            $messages = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            throw "Errors while loading config: $messages"
        }
        if ($result.Count -eq 0) { throw "Configuration file '$Path' did not produce expected values." }
        return $result[0]
    } finally {
        $ps.Dispose()
    }
}

function Initialize-WizardState {
    param([string]$RepositoryRoot, [string]$ConfigOutputPath)
    $state = [pscustomobject]@{
        RepositoryRoot = $RepositoryRoot
        ConfigOutputPath = $ConfigOutputPath
        UseExisting = $false
        ExistingConfigPath = ''
        SyncRoot = 'C:\\SyncHub'
        DirectoryLocalPictures = [Environment]::GetFolderPath('MyPictures')
        RemoteFilterPath = ''
        RemoteName = 'remote'
        DryRun = $true
        Bootstrap = $false
        RunSyncAfter = $false
        LastRemoteCheckMessage = ''
        LoadedConfigSnapshot = $null
        FinalResult = $null
    }

    $sample = Join-Path $RepositoryRoot 'userConfig.sample.ps1'
    if (Test-Path $sample) {
        try {
            $snapshot = Read-ConfigSnapshot -Path $sample
            if ($snapshot.SyncRoot) { $state.SyncRoot = $snapshot.SyncRoot }
            if ($snapshot.DirectoryLocalPictures) { $state.DirectoryLocalPictures = $snapshot.DirectoryLocalPictures }
            if ($snapshot.RemoteFilterPath) { $state.RemoteFilterPath = $snapshot.RemoteFilterPath }
            if ($null -ne $snapshot.DryRun) { $state.DryRun = [bool]$snapshot.DryRun }
            if ($null -ne $snapshot.Bootstrap) { $state.Bootstrap = [bool]$snapshot.Bootstrap }
        } catch {}
    }

    $cache = Load-WizardStateCache
    if ($cache) {
        if ($cache.SyncRoot) { $state.SyncRoot = $cache.SyncRoot }
        if ($cache.DirectoryLocalPictures) { $state.DirectoryLocalPictures = $cache.DirectoryLocalPictures }
        if ($cache.RemoteFilterPath) { $state.RemoteFilterPath = $cache.RemoteFilterPath }
        if ($cache.RemoteName) { $state.RemoteName = $cache.RemoteName }
        if ($null -ne $cache.DryRun) { $state.DryRun = [bool]$cache.DryRun }
        if ($null -ne $cache.Bootstrap) { $state.Bootstrap = [bool]$cache.Bootstrap }
        if ($cache.ConfigOutputPath) { $state.ConfigOutputPath = $cache.ConfigOutputPath }
        if ($null -ne $cache.RunSyncAfter) { $state.RunSyncAfter = [bool]$cache.RunSyncAfter }
    }

    if ([string]::IsNullOrWhiteSpace($state.RemoteFilterPath) -and $state.SyncRoot) {
        $state.RemoteFilterPath = Join-Path $state.SyncRoot 'remote_filter.txt'
    }
    if ([string]::IsNullOrWhiteSpace($state.DirectoryLocalPictures)) {
        $state.DirectoryLocalPictures = 'C:\\Users\\Public\\Pictures'
    }

    return $state
}

function Get-DerivedLogPreview {
    param([string]$SyncRoot)
    if ([string]::IsNullOrWhiteSpace($SyncRoot)) {
        return 'Log and metadata files will be stored beneath the sync root.'
    }
    $files = @('md5.sum','lastrun.txt','remote_filter.txt','log_remote_listing.txt','main_log.txt','consolidated_log.txt','includeFile.txt')
    $lines = @("These files will live under ${SyncRoot}:")
    foreach ($file in $files) { $lines += " - $file" }
    return $lines -join [Environment]::NewLine
}

function Get-WizardSummary {
    param([pscustomobject]$State)
    $remote = if ($State.RemoteName.EndsWith(':')) { $State.RemoteName } else { "${($State.RemoteName)}:" }
    $dry = if ($State.DryRun) { 'Yes' } else { 'No' }
    $bootstrap = if ($State.Bootstrap) { 'Yes' } else { 'No' }
    @(
        "Configuration file: $($State.ConfigOutputPath)",
        "Sync root: $($State.SyncRoot)",
        "Local folder: $($State.DirectoryLocalPictures)",
        "Remote filter: $($State.RemoteFilterPath)",
        "Remote name: $remote",
        "Dry-run by default: $dry",
        "Bootstrap mode: $bootstrap"
    ) -join [Environment]::NewLine
}

function Write-UserConfigFile {
    param([pscustomobject]$State)
    $path = $State.ConfigOutputPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
    $syncRootLiteral = ConvertTo-PsStringLiteral -Value $State.SyncRoot
    $localLiteral = ConvertTo-PsStringLiteral -Value $State.DirectoryLocalPictures
    $dryLiteral = if ($State.DryRun) { '$true' } else { '$false' }
    $bootstrapLiteral = if ($State.Bootstrap) { '$true' } else { '$false' }
    $relativeFilter = Get-RelativePath -BasePath $State.SyncRoot -TargetPath $State.RemoteFilterPath
    $filterLine = if ($relativeFilter) {
        '$global:FilePathRemoteFilter    = Join-Path $syncRoot ' + (ConvertTo-PsStringLiteral -Value $relativeFilter)
    } else {
        '$global:FilePathRemoteFilter    = ' + (ConvertTo-PsStringLiteral -Value $State.RemoteFilterPath)
    }
    $lines = @(
        "# userConfig.ps1 generated by Sync Wizard on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "",
        "`$syncRoot = $syncRootLiteral",
        "",
        '$global:FilePathMD5Sum          = Join-Path $syncRoot ''md5.sum''',
        '$global:FilePathLastRun         = Join-Path $syncRoot ''lastrun.txt''',
        $filterLine,
        '$global:FilePathLogRemoteListing = Join-Path $syncRoot ''log_remote_listing.txt''',
        '$global:FilePathFilterFile      = Join-Path $syncRoot ''filter-file.txt''',
        '$global:FilePathLogProdMD5      = Join-Path $syncRoot ''log_prod_md5.txt''',
        '$global:FilePathSumErrors       = Join-Path $syncRoot ''sumerrors.txt''',
        '$global:FilePathIncludeFile     = Join-Path $syncRoot ''includeFile.txt''',
        '$global:FilePathLogProdCopy     = Join-Path $syncRoot ''log_prod_copy.txt''',
        '$global:LogFile                 = Join-Path $syncRoot ''main_log.txt''',
        '$global:ConsolidatedLogFile     = Join-Path $syncRoot ''consolidated_log.txt''',
        '$global:LargeFileLog            = Join-Path $syncRoot ''large_debug_log.txt''',
        '$Global:StdOutFilePath          = Join-Path $syncRoot ''rclone_stdout.txt''',
        '$Global:StdErrFilePath          = Join-Path $syncRoot ''rclone_stderr.txt''',
        "",
        '$global:DirectoryLocalPictures = ' + $localLiteral,
        "",
        '$global:EventSource = ''ps_syncNew''',
        '$global:LogName     = ''pcloud_rclone''',
        "",
        '$global:DryRun    = ' + $dryLiteral + '   # Default to dry-run for safety',
        '$global:Bootstrap = ' + $bootstrapLiteral + '  # Set $true to ignore previous run timestamps',
        "",
        '$timestamp = (Get-Date).ToString(''yyyyMMdd_HHmmss'')',
        '$global:FilePathLogDuplicates = Join-Path $syncRoot "log_duplicates_$timestamp.txt"',
        ""
    )
    Set-Content -Path $path -Value $lines -Encoding UTF8
}

function Invoke-RcloneRemoteCheck {
    param([string]$RemoteName)
    if ([string]::IsNullOrWhiteSpace($RemoteName)) { return "Enter a remote name before checking." }
    $target = if ($RemoteName.EndsWith(':')) { $RemoteName } else { "${RemoteName}:" }
    $psi = [System.Diagnostics.ProcessStartInfo]::new('rclone','listremotes')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $output = $process.StandardOutput.ReadToEnd()
        $error = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($error)) { $error = "rclone exited with code $($process.ExitCode)." }
            return "Failed to query remotes: $error"
        }
        $remotes = $output -split "`r?`n" | Where-Object { $_ }
        if ($remotes -contains $target) { return "Remote '$target' is available." }
        return "Remote '$target' not found. Available remotes: $([string]::Join(', ', $remotes))"
    } catch {
        return "Failed to run rclone: $($_.Exception.Message)"
    }
}

function Start-SyncProcess {
    param([pscustomobject]$State)
    $scriptPath = Join-Path $State.RepositoryRoot 'pcloud_sync.ps1'
    if (-not (Test-Path $scriptPath)) { return "Could not find pcloud_sync.ps1 at $scriptPath." }
    $args = @('-NoLogo','-NoProfile','-File',"`"$scriptPath`"",'-ConfigPath',"`"$($State.ConfigOutputPath)`"")
    if (-not [string]::IsNullOrWhiteSpace($State.RemoteName)) {
        $args += @('-RemoteName',"`"$($State.RemoteName)`"")
    }
    try {
        $hostPath = Resolve-PowerShellHost
        if (-not $hostPath) { return 'Failed to locate pwsh or powershell to launch the sync.' }
        Start-Process -FilePath $hostPath -ArgumentList $args -WorkingDirectory $State.RepositoryRoot | Out-Null
        return 'Launched pcloud_sync.ps1 in a new PowerShell window.'
    } catch {
        return "Failed to launch sync: $($_.Exception.Message)"
    }
}

function Start-SyncWizard {
    param([string]$ConfigOutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'userConfig.ps1'))

    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Sync wizard requires STA. Re-run with pwsh -STA -File Start-SyncWizard.ps1.'
    }

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $state = Initialize-WizardState -RepositoryRoot $repositoryRoot -ConfigOutputPath $ConfigOutputPath

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'pcloud Sync Wizard'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.AutoScaleMode = 'Font'
    $form.Size = New-Object System.Drawing.Size(780, 640)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 520)
    $form.StartPosition = 'CenterScreen'

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'

    $tabSource = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Source'; UseVisualStyleBackColor = $true }
    $tabSync   = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Sync Root'; UseVisualStyleBackColor = $true }
    $tabLocal  = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Local'; UseVisualStyleBackColor = $true }
    $tabRemote = New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Remote'; UseVisualStyleBackColor = $true }
    $tabOptions= New-Object System.Windows.Forms.TabPage -Property @{ Text = 'Options'; UseVisualStyleBackColor = $true }
    $tabs.TabPages.AddRange(@($tabSource,$tabSync,$tabLocal,$tabRemote,$tabOptions))
    $form.Controls.Add($tabs)

    $padding = New-Object System.Windows.Forms.Padding(12)

    function New-Layout {
        param($columns, $rows)
        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.Dock = 'Fill'
        $layout.Padding = $padding
        $layout.ColumnCount = $columns.Count
        $layout.RowCount = $rows.Count
        foreach ($def in $columns) {
            $sizeType = [System.Enum]::Parse([System.Windows.Forms.SizeType], $def.Type)
            $layout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new($sizeType, $def.Value))
        }
        foreach ($def in $rows) {
            $sizeType = [System.Enum]::Parse([System.Windows.Forms.SizeType], $def.Type)
            $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new($sizeType, $def.Value))
        }
        return $layout
    }
    $sourceLayout = New-Layout @(
        @{ Type = 'Percent'; Value = 100 }
        @{ Type = 'AutoSize'; Value = 0 }
    ) @(
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
    )

    $radioNew = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Create a new configuration'; AutoSize = $true }
    $radioExisting = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Use an existing configuration file'; AutoSize = $true }
    $existingPath = New-Object System.Windows.Forms.TextBox -Property @{ Dock = 'Fill' }
    $existingBrowse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; AutoSize = $true }
    $sourceStatus = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(620,0) }

    $sourceLayout.Controls.Add($radioNew,0,0)
    [void]$sourceLayout.SetColumnSpan($radioNew,2)
    $sourceLayout.Controls.Add($radioExisting,0,1)
    [void]$sourceLayout.SetColumnSpan($radioExisting,2)
    $sourceLayout.Controls.Add($existingPath,0,2)
    $sourceLayout.Controls.Add($existingBrowse,1,2)
    $sourceLayout.Controls.Add($sourceStatus,0,3)
    [void]$sourceLayout.SetColumnSpan($sourceStatus,2)
    $tabSource.Controls.Add($sourceLayout)

    $syncLayout = New-Layout @(
        @{ Type = 'Percent'; Value = 100 }
        @{ Type = 'AutoSize'; Value = 0 }
    ) @(
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'Percent'; Value = 100 }
    )

    $syncLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'Sync root folder:'; AutoSize = $true }
    $syncPath = New-Object System.Windows.Forms.TextBox -Property @{ Dock = 'Fill' }
    $syncBrowse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; AutoSize = $true }
    $syncInfo = New-Object System.Windows.Forms.TextBox -Property @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Dock = 'Fill' }

    $syncLayout.Controls.Add($syncLabel,0,0)
    [void]$syncLayout.SetColumnSpan($syncLabel,2)
    $syncLayout.Controls.Add($syncPath,0,1)
    $syncLayout.Controls.Add($syncBrowse,1,1)
    $syncLayout.Controls.Add($syncInfo,0,2)
    [void]$syncLayout.SetColumnSpan($syncInfo,2)
    $tabSync.Controls.Add($syncLayout)

    $localLayout = New-Layout @(
        @{ Type = 'Percent'; Value = 100 }
        @{ Type = 'AutoSize'; Value = 0 }
    ) @(
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
    )

    $localLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'Local destination folder:'; AutoSize = $true }
    $localPath = New-Object System.Windows.Forms.TextBox -Property @{ Dock = 'Fill' }
    $localBrowse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; AutoSize = $true }

    $localLayout.Controls.Add($localLabel,0,0)
    [void]$localLayout.SetColumnSpan($localLabel,2)
    $localLayout.Controls.Add($localPath,0,1)
    $localLayout.Controls.Add($localBrowse,1,1)
    $tabLocal.Controls.Add($localLayout)

    $remoteLayout = New-Layout @(
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'Percent'; Value = 100 }
        @{ Type = 'AutoSize'; Value = 0 }
    ) @(
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'Percent'; Value = 100 }
    )

    $remoteNameLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'Remote name:'; AutoSize = $true }
    $remoteName = New-Object System.Windows.Forms.TextBox -Property @{ Dock = 'Fill' }
    $remoteCheck = New-Object System.Windows.Forms.Button -Property @{ Text = 'Check remote'; AutoSize = $true }
    $filterLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'Filter file:'; AutoSize = $true }
    $filterPath = New-Object System.Windows.Forms.TextBox -Property @{ Dock = 'Fill' }
    $filterButtons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false }
    $filterBrowse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; AutoSize = $true }
    $filterCreate = New-Object System.Windows.Forms.Button -Property @{ Text = 'Create'; AutoSize = $true }
    $filterButtons.Controls.AddRange(@($filterBrowse,$filterCreate))
    $remoteStatus = New-Object System.Windows.Forms.Label -Property @{ AutoSize = $true; MaximumSize = [System.Drawing.Size]::new(620,0) }

    $remoteLayout.Controls.Add($remoteNameLabel,0,0)
    $remoteLayout.Controls.Add($remoteName,1,0)
    $remoteLayout.Controls.Add($remoteCheck,2,0)
    $remoteLayout.Controls.Add($filterLabel,0,1)
    $remoteLayout.Controls.Add($filterPath,1,1)
    $remoteLayout.Controls.Add($filterButtons,2,1)
    $remoteLayout.Controls.Add($remoteStatus,0,2)
    [void]$remoteLayout.SetColumnSpan($remoteStatus,3)
    $tabRemote.Controls.Add($remoteLayout)

    $optionsLayout = New-Layout @(
        @{ Type = 'Percent'; Value = 100 }
        @{ Type = 'AutoSize'; Value = 0 }
    ) @(
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'AutoSize'; Value = 0 }
        @{ Type = 'Percent'; Value = 100 }
    )

    $dryCheck = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Default to dry-run mode'; AutoSize = $true }
    $bootstrapCheck = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Enable bootstrap mode (ignore last run timestamp)'; AutoSize = $true }
    $runCheck = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Launch pcloud_sync.ps1 immediately after saving'; AutoSize = $true }
    $configLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'Config output path:'; AutoSize = $true }
    $configPath = New-Object System.Windows.Forms.TextBox -Property @{ Dock = 'Fill' }
    $configBrowse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; AutoSize = $true }
    $summaryLabel = New-Object System.Windows.Forms.Label -Property @{ Text = 'Summary:'; AutoSize = $true }
    $summaryBox = New-Object System.Windows.Forms.TextBox -Property @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Dock = 'Fill' }

    $optionsLayout.Controls.Add($dryCheck,0,0)
    [void]$optionsLayout.SetColumnSpan($dryCheck,2)
    $optionsLayout.Controls.Add($bootstrapCheck,0,1)
    [void]$optionsLayout.SetColumnSpan($bootstrapCheck,2)
    $optionsLayout.Controls.Add($runCheck,0,2)
    [void]$optionsLayout.SetColumnSpan($runCheck,2)
    $optionsLayout.Controls.Add($configLabel,0,3)
    [void]$optionsLayout.SetColumnSpan($configLabel,2)
    $optionsLayout.Controls.Add($configPath,0,4)
    $optionsLayout.Controls.Add($configBrowse,1,4)
    $optionsLayout.Controls.Add($summaryLabel,0,5)
    [void]$optionsLayout.SetColumnSpan($summaryLabel,2)
    $optionsLayout.Controls.Add($summaryBox,0,6)
    [void]$optionsLayout.SetColumnSpan($summaryBox,2)
    $tabOptions.Controls.Add($optionsLayout)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Bottom'; FlowDirection = 'RightToLeft'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = [System.Windows.Forms.Padding]::new(12,8,12,12) }
    $saveButton = New-Object System.Windows.Forms.Button -Property @{ Text = 'Save'; AutoSize = $true }
    $cancelButton = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; AutoSize = $true }
    $buttonPanel.Controls.AddRange(@($cancelButton,$saveButton))
    $form.Controls.Add($buttonPanel)
    $updateSummary = {
        $temp = [pscustomobject]@{
            ConfigOutputPath = $configPath.Text
            SyncRoot = $syncPath.Text
            DirectoryLocalPictures = $localPath.Text
            RemoteFilterPath = $filterPath.Text
            RemoteName = $remoteName.Text
            DryRun = $dryCheck.Checked
            Bootstrap = $bootstrapCheck.Checked
        }
        $summaryBox.Text = Get-WizardSummary -State $temp
    }.GetNewClosure()

    $updateSyncPreview = {
        $syncInfo.Text = Get-DerivedLogPreview -SyncRoot $syncPath.Text
    }.GetNewClosure()

    $updateSourceControls = {
        $enabled = $radioExisting.Checked
        $existingPath.Enabled = $enabled
        $existingBrowse.Enabled = $enabled
    }.GetNewClosure()

    $existingBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'PowerShell files (*.ps1)|*.ps1|All files (*.*)|*.*'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -eq 'OK') {
            $existingPath.Text = $dialog.FileName
            $radioExisting.Checked = $true
        }
    }.GetNewClosure())

    $syncBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select a folder to store sync metadata'
        if ($dialog.ShowDialog() -eq 'OK') {
            $syncPath.Text = $dialog.SelectedPath
            if ([string]::IsNullOrWhiteSpace($filterPath.Text)) {
                $filterPath.Text = Join-Path $dialog.SelectedPath 'remote_filter.txt'
            }
            $updateSyncPreview.Invoke()
            $updateSummary.Invoke()
        }
    }.GetNewClosure())

    $localBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select the local destination folder'
        if ($dialog.ShowDialog() -eq 'OK') {
            $localPath.Text = $dialog.SelectedPath
            $updateSummary.Invoke()
        }
    }.GetNewClosure())

    $remoteCheck.Add_Click({
        $message = Invoke-RcloneRemoteCheck -RemoteName $remoteName.Text.Trim()
        $remoteStatus.Text = $message
        $remoteStatus.ForeColor = if ($message -like 'Remote * available*') { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkGoldenrod }
        $state.LastRemoteCheckMessage = $message
    }.GetNewClosure())

    $filterBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $dialog.CheckFileExists = $false
        if ($dialog.ShowDialog() -eq 'OK') {
            $filterPath.Text = $dialog.FileName
            $updateSummary.Invoke()
        }
    }.GetNewClosure())

    $filterCreate.Add_Click({
        $path = $filterPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) {
            [System.Windows.Forms.MessageBox]::Show('Enter a file path before creating it.','Create Filter',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        try {
            $dir = Split-Path -Parent $path
            if ($dir -and -not (Test-Path $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
            if (-not (Test-Path $path)) {
                Set-Content -Path $path -Value "# Include folders or files relative to the remote root`n" -Encoding UTF8
            }
            [System.Windows.Forms.MessageBox]::Show("Filter file ensured at $path.",'Create Filter',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to create filter file: $($_.Exception.Message)",'Create Filter',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }.GetNewClosure())

    $configBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'PowerShell files (*.ps1)|*.ps1|All files (*.*)|*.*'
        $dialog.FileName = [System.IO.Path]::GetFileName($configPath.Text)
        if ($dialog.ShowDialog() -eq 'OK') {
            $configPath.Text = $dialog.FileName
            $updateSummary.Invoke()
        }
    }.GetNewClosure())

    $radioNew.Add_CheckedChanged({ $updateSourceControls.Invoke() })
    $radioExisting.Add_CheckedChanged({ $updateSourceControls.Invoke() })
    $syncPath.Add_TextChanged({ $updateSyncPreview.Invoke(); $updateSummary.Invoke() })
    $localPath.Add_TextChanged({ $updateSummary.Invoke() })
    $filterPath.Add_TextChanged({ $updateSummary.Invoke() })
    $configPath.Add_TextChanged({ $updateSummary.Invoke() })
    $remoteName.Add_TextChanged({ $updateSummary.Invoke() })
    $dryCheck.Add_CheckedChanged({ $updateSummary.Invoke() })
    $bootstrapCheck.Add_CheckedChanged({ $updateSummary.Invoke() })

    $saveButton.Add_Click({
        if ($radioExisting.Checked) {
            $path = $existingPath.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
                [System.Windows.Forms.MessageBox]::Show('Select a valid configuration file to continue.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            try {
                $snapshot = Read-ConfigSnapshot -Path $path
                $state.UseExisting = $true
                $state.ConfigOutputPath = $path
                $state.ExistingConfigPath = $path
                if ($snapshot.SyncRoot) { $state.SyncRoot = $snapshot.SyncRoot }
                if ($snapshot.DirectoryLocalPictures) { $state.DirectoryLocalPictures = $snapshot.DirectoryLocalPictures }
                if ($snapshot.RemoteFilterPath) { $state.RemoteFilterPath = $snapshot.RemoteFilterPath }
                if ($null -ne $snapshot.DryRun) { $state.DryRun = [bool]$snapshot.DryRun }
                if ($null -ne $snapshot.Bootstrap) { $state.Bootstrap = [bool]$snapshot.Bootstrap }
            } catch {
                $sourceStatus.ForeColor = [System.Drawing.Color]::Firebrick
                $sourceStatus.Text = $_.Exception.Message
                return
            }
        } else {
            $state.UseExisting = $false
            $state.ExistingConfigPath = ''
        }

        $syncRoot = $syncPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($syncRoot)) {
            [System.Windows.Forms.MessageBox]::Show('Select a sync root to continue.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not (Test-Path $syncRoot)) {
            $result = [System.Windows.Forms.MessageBox]::Show("Folder '$syncRoot' does not exist. Create it now?",'Create Folder',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                try { $null = New-Item -Path $syncRoot -ItemType Directory -Force } catch {
                    [System.Windows.Forms.MessageBox]::Show("Failed to create folder: $($_.Exception.Message)",'Create Folder',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
            } else { return }
        }
        $state.SyncRoot = $syncRoot

        $localFolder = $localPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($localFolder)) {
            [System.Windows.Forms.MessageBox]::Show('Select a local destination folder.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not (Test-Path $localFolder)) {
            $result = [System.Windows.Forms.MessageBox]::Show("Folder '$localFolder' does not exist. Create it now?",'Create Folder',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                try { $null = New-Item -Path $localFolder -ItemType Directory -Force } catch {
                    [System.Windows.Forms.MessageBox]::Show("Failed to create folder: $($_.Exception.Message)",'Create Folder',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
            } else { return }
        }
        $state.DirectoryLocalPictures = $localFolder

        $remote = $remoteName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($remote)) {
            [System.Windows.Forms.MessageBox]::Show('Enter an rclone remote name.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $state.RemoteName = $remote

        $filter = $filterPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($filter)) {
            [System.Windows.Forms.MessageBox]::Show('Select an rclone filter file.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not (Test-Path $filter)) {
            $result = [System.Windows.Forms.MessageBox]::Show("Filter file '$filter' does not exist. Create it now?",'Create Filter',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                try {
                    $dir = Split-Path -Parent $filter
                    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
                    Set-Content -Path $filter -Value "# Include folders or files relative to the remote root`n" -Encoding UTF8
                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Failed to create filter file: $($_.Exception.Message)",'Create Filter',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                    return
                }
            } else { return }
        }
        $state.RemoteFilterPath = $filter

        $state.DryRun = $dryCheck.Checked
        $state.Bootstrap = $bootstrapCheck.Checked
        $state.RunSyncAfter = $runCheck.Checked

        $config = $configPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($config)) {
            [System.Windows.Forms.MessageBox]::Show('Specify where to save the configuration file.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $state.ConfigOutputPath = $config

        try {
            Write-UserConfigFile -State $state
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Failed to write configuration',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
        Save-WizardStateCache -State $state
        $messages = @("Configuration saved to $config.")
        if ($state.RunSyncAfter) { $messages += Start-SyncProcess -State $state }
        [System.Windows.Forms.MessageBox]::Show(($messages -join [Environment]::NewLine),'Wizard Complete',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $state.FinalResult = [pscustomobject]@{
            ConfigPath = $state.ConfigOutputPath
            SyncStarted = $state.RunSyncAfter
            RemoteName = $state.RemoteName
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    }.GetNewClosure())

    $cancelButton.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    }.GetNewClosure())

    $radioExisting.Checked = $state.UseExisting
    $radioNew.Checked = -not $state.UseExisting
    $existingPath.Text = if ($state.UseExisting) { $state.ConfigOutputPath } else { $state.ExistingConfigPath }
    $syncPath.Text = $state.SyncRoot
    $localPath.Text = $state.DirectoryLocalPictures
    $remoteName.Text = $state.RemoteName
    $filterPath.Text = $state.RemoteFilterPath
    $dryCheck.Checked = $state.DryRun
    $bootstrapCheck.Checked = $state.Bootstrap
    $runCheck.Checked = $state.RunSyncAfter
    $configPath.Text = $state.ConfigOutputPath
    if (-not [string]::IsNullOrWhiteSpace($state.LastRemoteCheckMessage)) {
        $remoteStatus.Text = $state.LastRemoteCheckMessage
    }

    $updateSourceControls.Invoke()
    $updateSyncPreview.Invoke()
    $updateSummary.Invoke()

    $null = $form.ShowDialog()
    return $state.FinalResult
}

Export-ModuleMember -Function Start-SyncWizard


