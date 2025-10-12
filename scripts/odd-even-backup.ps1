<#
.SYNOPSIS
    Start a graphical backup utility that mirrors a folder to alternating USB drives and optionally shuts down afterwards.

.DESCRIPTION
    Configure the SourcePath and the two target drives below. Launching the script opens a small
    Windows Forms interface with a start button, live status messages and a checkbox that controls
    whether the computer should power off after the backup. The script chooses the appropriate
    drive depending on whether the current calendar day is odd or even, mirrors the configured
    source folder with Robocopy (including retry logic) and stores a log file for every run.

.NOTES
    Requires Windows PowerShell 5.1 (ships with Windows 11) and must be executed in an STA runspace.
    Run the script without elevated rights. If the shutdown option is selected, the utility triggers
    the standard Windows shutdown procedure once the copy job succeeded.
#>

$ErrorActionPreference = 'Stop'

$script:LogRoot = Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WinbackLogs'
[System.IO.Directory]::CreateDirectory($script:LogRoot) | Out-Null
$script:LauncherLogPath = Join-Path -Path $script:LogRoot -ChildPath 'launcher.log'

function Write-LauncherLog {
    param(
        [Parameter(Mandatory)] [string] $Message
    )

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $script:LauncherLogPath -Value "[$timestamp] $Message" -Encoding UTF8
    }
    catch {
        Write-Warning "Konnte Startprotokoll nicht schreiben: $($_.Exception.Message)"
    }
}

Write-LauncherLog -Message 'Skriptstart'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    Write-LauncherLog -Message 'Neustart mit STA-Anforderung'

    try {
        $powerShellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop).Source
        $psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{
            FileName         = $powerShellPath
            Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
            UseShellExecute  = $true
            WorkingDirectory = Split-Path -Parent $PSCommandPath
        }

        $process = [System.Diagnostics.Process]::Start($psi)

        if (-not $process) {
            throw "Der Neustart des Skripts konnte nicht ausgeloest werden."
        }
    }
    catch {
        Write-LauncherLog -Message "Neustart fehlgeschlagen: $($_.Exception.Message)"

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show(
                "Die Benutzeroberflaeche konnte nicht gestartet werden. Bitte die Datei '$script:LauncherLogPath' pruefen.",
                'Winback Sicherung',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        catch {
            Write-Error "Die Benutzeroberflaeche konnte nicht gestartet werden: $($_.Exception.Message)"
            Start-Sleep -Seconds 8
        }
    }

    return
}

Write-LauncherLog -Message 'STA-Laufzeit aktiv'

try {

#region --- User configuration -------------------------------------------------
# Path to the folder you want to back up.
$SourcePath = "C:\\Path\\To\\Folder"

# Target locations for even and odd days. Configure either a fixed Path, or
# describe the USB drive via VolumeLabel and optional DriveLetter together with
# a RelativePath on that drive. Using the label allows Windows to assign any
# letter while the script still finds the correct disk.
$EvenDayTargetConfig = @{
    VolumeLabel = 'Festplatte A'
    RelativePath = 'Backups'
}

$OddDayTargetConfig = @{
    VolumeLabel = 'Festplatte B'
    RelativePath = 'Backups'
}

# Optional: set to $true to keep a timestamped subfolder per run instead of mirroring.
$UseTimestampFolder = $false

# Timestamp format for created folders when $UseTimestampFolder is enabled. Invalid
# characters for Windows paths are automatically replaced with underscores.
$TimestampFolderFormat = 'yyyy_MM_dd-HH:mm'

# Folder to store Robocopy logs. Will be created if it doesn't exist.
$LogDirectory = $script:LogRoot
#endregion ---------------------------------------------------------------------

function Ensure-Directory {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-FriendlyErrorMessage {
    param(
        [Parameter()] [object] $ErrorObject,
        [string] $Fallback = 'Es ist ein unbekannter Fehler aufgetreten.'
    )

    $message = $null

    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $message = $ErrorObject.Exception.Message

        if ([string]::IsNullOrWhiteSpace($message) -and $ErrorObject.Exception -and $ErrorObject.Exception.InnerException) {
            $message = $ErrorObject.Exception.InnerException.Message
        }

        if ([string]::IsNullOrWhiteSpace($message) -and $ErrorObject.FullyQualifiedErrorId) {
            $message = $ErrorObject.FullyQualifiedErrorId
        }
    }
    elseif ($ErrorObject -is [System.Exception]) {
        $message = $ErrorObject.Message

        if ([string]::IsNullOrWhiteSpace($message) -and $ErrorObject.InnerException) {
            $message = $ErrorObject.InnerException.Message
        }
    }
    elseif ($ErrorObject) {
        $message = $ErrorObject.ToString()
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $Fallback
    }

    return $message.Trim()
}

function Show-UiError {
    param(
        [Parameter()] [object] $ErrorObject,
        [string] $Fallback = 'Es ist ein unbekannter Fehler aufgetreten.',
        [string] $Title = 'Backup-Fehler'
    )

    $message = Get-FriendlyErrorMessage -ErrorObject $ErrorObject -Fallback $Fallback
    Show-ErrorDialog -Message $message -Title $Title

    return $message
}

function Get-ConfigDescription {
    param(
        [Parameter(Mandatory)] [hashtable] $Config
    )

    if ($Config.ContainsKey('Path') -and $Config.Path) {
        return [Environment]::ExpandEnvironmentVariables($Config.Path)
    }

    $labelPart = if ($Config.ContainsKey('VolumeLabel') -and $Config.VolumeLabel) {
        $Config.VolumeLabel
    }

    $drivePart = if ($Config.ContainsKey('DriveLetter') -and $Config.DriveLetter) {
        'Laufwerk ' + ($Config.DriveLetter.ToString().TrimEnd(':').ToUpper())
    }

    $targetPart = if ($labelPart -and $drivePart) {
        "$labelPart ($drivePart)"
    }
    elseif ($labelPart) {
        $labelPart
    }
    elseif ($drivePart) {
        $drivePart
    }

    if ($Config.ContainsKey('RelativePath') -and $Config.RelativePath) {
        if ($targetPart) {
            return "$targetPart → $($Config.RelativePath)"
        }

        return $Config.RelativePath
    }

    if ($targetPart) {
        return $targetPart
    }

    return 'Nicht konfiguriert'
}

function Resolve-DriveRoot {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $RoleDescription
    )

    if ($Config.ContainsKey('Path') -and $Config.Path) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Config.Path)
        $root = [System.IO.Path]::GetPathRoot($expanded)

        if (-not $root) {
            throw "Der Pfad '$expanded' ist ungueltig. Bitte einen absoluten Zielpfad angeben."
        }

        return [PSCustomObject]@{
            DriveRoot = $root
            BasePath  = $expanded
        }
    }

    if ($Config.ContainsKey('DriveLetter') -and $Config.DriveLetter) {
        $letter = $Config.DriveLetter.ToString().TrimEnd(':')

        if ([string]::IsNullOrWhiteSpace($letter)) {
            throw "Die Laufwerksangabe fuer $RoleDescription Tage enthaelt keinen gueltigen Buchstaben."
        }

        $driveRoot = "{0}:\" -f $letter.ToUpper()

        if ($Config.ContainsKey('RelativePath') -and $Config.RelativePath) {
            $basePath = Join-Path -Path $driveRoot -ChildPath $Config.RelativePath
        }
        else {
            $basePath = $driveRoot
        }

        return [PSCustomObject]@{
            DriveRoot = $driveRoot
            BasePath  = $basePath
        }
    }

    if ($Config.ContainsKey('VolumeLabel') -and $Config.VolumeLabel) {
        try {
            $drive = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
                Where-Object { $_.VolumeName -eq $Config.VolumeLabel }
        }
        catch {
            throw "Die Laufwerksinformationen konnten nicht ermittelt werden: $($_.Exception.Message)"
        }

        if ($drive -is [System.Array]) {
            $drive = $drive | Select-Object -First 1
        }

        if (-not $drive) {
            throw "Das Laufwerk fuer $RoleDescription Tage mit dem Namen '$($Config.VolumeLabel)' wurde nicht gefunden."
        }

        $driveRoot = $drive.DeviceID + '\\'

        if ($Config.ContainsKey('RelativePath') -and $Config.RelativePath) {
            $basePath = Join-Path -Path $driveRoot -ChildPath $Config.RelativePath
        }
        else {
            $basePath = $driveRoot
        }

        return [PSCustomObject]@{
            DriveRoot = $driveRoot
            BasePath  = $basePath
        }
    }

    throw "Konfiguration fuer $RoleDescription Tage ist unvollstaendig. Bitte entweder Path oder VolumeLabel/DriveLetter angeben."
}

function Get-TimestampFolderInfo {
    param(
        [Parameter(Mandatory)] [DateTime] $Date,
        [Parameter()] [string] $Format = 'yyyy_MM_dd-HH:mm'
    )

    try {
        $raw = $Date.ToString($Format)
    }
    catch {
        $raw = $Date.ToString('yyyy_MM_dd-HHmm')
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $raw.ToCharArray()) {
        if ($invalidChars -contains $char) {
            [void]$builder.Append('_')
        }
        else {
            [void]$builder.Append($char)
        }
    }

    if ($builder.Length -eq 0) {
        $fallback = $Date.ToString('yyyyMMddHHmmss')
        [void]$builder.Append($fallback)
    }

    return [PSCustomObject]@{
        Display   = $raw
        Sanitized = $builder.ToString()
    }
}

function Get-TargetInfo {
    param(
        [Parameter(Mandatory)] [DateTime] $Date,
        [Parameter(Mandatory)] [hashtable] $EvenConfig,
        [Parameter(Mandatory)] [hashtable] $OddConfig,
        [bool] $Timestamped = $false,
        [string] $TimestampFormat = 'yyyy_MM_dd-HH:mm'
    )

    $isEvenDay = ($Date.Day % 2) -eq 0
    $roleDescription = if ($isEvenDay) { 'gerade' } else { 'ungerade' }
    $config = if ($isEvenDay) { $EvenConfig } else { $OddConfig }

    $resolved = Resolve-DriveRoot -Config $config -RoleDescription "$roleDescription"

    if ($Timestamped) {
        $timestampInfo = Get-TimestampFolderInfo -Date $Date -Format $TimestampFormat
        $destination = Join-Path -Path $resolved.BasePath -ChildPath $timestampInfo.Sanitized
        $displayName = $timestampInfo.Display
    }
    else {
        $destination = $resolved.BasePath
        $displayName = $null
    }

    return [PSCustomObject]@{
        RoleDescription = $roleDescription
        DriveRoot       = $resolved.DriveRoot
        BasePath        = $resolved.BasePath
        DestinationPath = $destination
        TimestampLabel  = $displayName
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

function Show-ErrorDialog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Title = 'Backup-Fehler'
    )

    [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

$accentColor   = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
$successColor  = [System.Drawing.ColorTranslator]::FromHtml('#047857')
$errorColor    = [System.Drawing.ColorTranslator]::FromHtml('#B91C1C')
$neutralColor  = [System.Drawing.ColorTranslator]::FromHtml('#1F2933')
$surfaceColor  = [System.Drawing.Color]::White
$backgroundCol = [System.Drawing.ColorTranslator]::FromHtml('#F5F7FB')

$form = New-Object System.Windows.Forms.Form -Property @{
    Text            = 'Winback Sicherung'
    Size            = New-Object System.Drawing.Size(720, 560)
    MinimumSize     = New-Object System.Drawing.Size(720, 560)
    FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    MaximizeBox     = $false
    StartPosition   = 'CenterScreen'
    BackColor       = $backgroundCol
}
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$tableLayout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
    Dock        = 'Fill'
    ColumnCount = 1
    RowCount    = 4
    BackColor   = $backgroundCol
    Padding     = New-Object System.Windows.Forms.Padding(14)
}
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$form.Controls.Add($tableLayout)

$evenDescription = Get-ConfigDescription -Config $EvenDayTargetConfig
$oddDescription  = Get-ConfigDescription -Config $OddDayTargetConfig

$headerPanel = New-Object System.Windows.Forms.Panel -Property @{
    BackColor = $surfaceColor
    AutoSize  = $true
    Dock      = 'Top'
    Padding   = New-Object System.Windows.Forms.Padding(16)
    Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
}

$headerTitle = New-Object System.Windows.Forms.Label -Property @{
    Text      = 'Konfiguration'
    Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    ForeColor = $accentColor
    AutoSize  = $true
    Dock      = 'Top'
}
$headerPanel.Controls.Add($headerTitle)

$infoLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize     = $true
    Dock         = 'Top'
    MaximumSize  = New-Object System.Drawing.Size(520, 0)
    Padding      = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    Text         = "Quelle: $SourcePath`r`nGerade Tage: $evenDescription`r`nUngerade Tage: $oddDescription"
    ForeColor    = $neutralColor
}
$headerPanel.Controls.Add($infoLabel)
$tableLayout.Controls.Add($headerPanel, 0, 0)

$statusPanel = New-Object System.Windows.Forms.Panel -Property @{
    BackColor = $surfaceColor
    AutoSize  = $true
    Dock      = 'Top'
    Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
}

$statusCaption = New-Object System.Windows.Forms.Label -Property @{
    Text     = 'Status'
    AutoSize = $true
    Font     = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    ForeColor = $accentColor
    Dock     = 'Top'
}
$statusPanel.Controls.Add($statusCaption)

$statusLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize  = $true
    Dock      = 'Top'
    Font      = New-Object System.Drawing.Font('Segoe UI', 10)
    ForeColor = $neutralColor
    Padding   = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    Text      = 'Bereit fuer Sicherung.'
}
$statusPanel.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar -Property @{
    Style                 = [System.Windows.Forms.ProgressBarStyle]::Marquee
    MarqueeAnimationSpeed = 28
    Visible               = $false
    Dock                  = 'Top'
}
$progressBar.Height = 18
$progressBar.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$statusPanel.Controls.Add($progressBar)

$tableLayout.Controls.Add($statusPanel, 0, 1)

$logGroup = New-Object System.Windows.Forms.GroupBox -Property @{
    Text     = 'Protokollauszug'
    Dock     = 'Fill'
    Padding  = New-Object System.Windows.Forms.Padding(16, 26, 16, 16)
    BackColor = $surfaceColor
    ForeColor = $neutralColor
}

$logTextBox = New-Object System.Windows.Forms.TextBox -Property @{
    Multiline  = $true
    ScrollBars = 'Vertical'
    ReadOnly   = $true
    Dock       = 'Fill'
    Font       = New-Object System.Drawing.Font('Consolas', 9)
    BackColor  = [System.Drawing.Color]::White
    BorderStyle = [System.Windows.Forms.BorderStyle]::None
}
$logTextBox.Margin = New-Object System.Windows.Forms.Padding(0)
$logGroup.Controls.Add($logTextBox)
$tableLayout.Controls.Add($logGroup, 0, 2)

$footerLayout = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
    ColumnCount = 2
    AutoSize    = $true
    Dock        = 'Top'
    Margin      = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
    BackColor   = [System.Drawing.Color]::Transparent
}
$footerLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$footerLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

$shutdownCheckbox = New-Object System.Windows.Forms.CheckBox -Property @{
    AutoSize = $true
    Text     = 'Nach erfolgreichem Backup herunterfahren'
    ForeColor = $neutralColor
    Dock     = 'Left'
}
$footerLayout.Controls.Add($shutdownCheckbox, 0, 0)

$buttonFlow = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
    FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    AutoSize      = $true
    Dock          = 'Fill'
    WrapContents  = $false
    BackColor     = [System.Drawing.Color]::Transparent
}

$startButton = New-Object System.Windows.Forms.Button -Property @{
    Text                   = 'Backup starten'
    AutoSize               = $true
    Padding                = New-Object System.Windows.Forms.Padding(16, 6, 16, 6)
    BackColor              = $accentColor
    ForeColor              = [System.Drawing.Color]::White
    FlatStyle              = [System.Windows.Forms.FlatStyle]::Flat
    UseVisualStyleBackColor = $false
}
$startButton.FlatAppearance.BorderSize = 0
$startButton.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)

$openLogButton = New-Object System.Windows.Forms.Button -Property @{
    Text                   = 'Logdatei oeffnen'
    AutoSize               = $true
    Padding                = New-Object System.Windows.Forms.Padding(16, 6, 16, 6)
    Enabled                = $false
    BackColor              = [System.Drawing.ColorTranslator]::FromHtml('#E5E7EB')
    ForeColor              = $neutralColor
    FlatStyle              = [System.Windows.Forms.FlatStyle]::Flat
    UseVisualStyleBackColor = $false
}
$openLogButton.FlatAppearance.BorderSize = 0
$openLogButton.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)

$closeButton = New-Object System.Windows.Forms.Button -Property @{
    Text                   = 'Schliessen'
    AutoSize               = $true
    Padding                = New-Object System.Windows.Forms.Padding(16, 6, 16, 6)
    BackColor              = [System.Drawing.ColorTranslator]::FromHtml('#F3F4F6')
    ForeColor              = $neutralColor
    FlatStyle              = [System.Windows.Forms.FlatStyle]::Flat
    UseVisualStyleBackColor = $false
}
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)

$buttonFlow.Controls.Add($startButton)
$buttonFlow.Controls.Add($openLogButton)
$buttonFlow.Controls.Add($closeButton)

$footerLayout.Controls.Add($buttonFlow, 1, 0)
$tableLayout.Controls.Add($footerLayout, 0, 3)

$form.AcceptButton = $startButton
$form.CancelButton = $closeButton

$script:defaultStatusColor = $neutralColor

function Set-Status {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [System.Drawing.Color] $Color = $script:defaultStatusColor,
        [bool] $IsRunning = $false
    )

    $statusLabel.Text = $Text
    $statusLabel.ForeColor = $Color
    $progressBar.Visible = $IsRunning
}

Set-Status -Text 'Bereit fuer Sicherung.' -Color $neutralColor -IsRunning:$false

$script:currentLogFile = $null
$script:activeBackup   = $null

$pollTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 750 }
$pollTimer.add_Tick({
    if ($script:activeBackup -and $script:activeBackup.Process -and $script:activeBackup.Process.HasExited) {
        $pollTimer.Stop()
        Complete-Backup
    }
})

function Start-BackupRun {
    $logTextBox.Clear()
    $openLogButton.Enabled = $false

    try {
        if ($script:activeBackup) {
            Write-LauncherLog -Message 'Sicherung bereits aktiv, Start ignoriert.'
            return
        }

        Set-Status -Text 'Pruefe Pfade und Laufwerke ...' -Color $accentColor -IsRunning $true

        if (-not (Test-Path -LiteralPath $SourcePath)) {
            throw "Der Quellordner '$SourcePath' wurde nicht gefunden. Bitte Konfiguration pruefen."
        }

        $today      = Get-Date
        $targetInfo = Get-TargetInfo -Date $today -EvenConfig $EvenDayTargetConfig -OddConfig $OddDayTargetConfig -Timestamped:$UseTimestampFolder -TimestampFormat $TimestampFolderFormat

        if ($targetInfo.DriveRoot -and -not (Test-Path -LiteralPath $targetInfo.DriveRoot)) {
            throw "Das Laufwerk fuer $($targetInfo.RoleDescription) Tage ist nicht erreichbar. Bitte die passende USB-Festplatte anschliessen."
        }

        $targetRoot  = $targetInfo.DestinationPath
        $logFileName = "backup-" + $today.ToString('yyyy-MM-dd_HHmmss') + '.log'
        $logFile     = Join-Path -Path $LogDirectory -ChildPath $logFileName

        $logTextBox.AppendText("Ziel ($($targetInfo.RoleDescription) Tage): $targetRoot`r`n")
        if ($targetInfo.TimestampLabel) {
            $logTextBox.AppendText("Zeitstempel: $($targetInfo.TimestampLabel)`r`n")
        }
        $logTextBox.AppendText("Robocopy-Protokoll: $logFile`r`n`r`n")

        $startButton.Enabled = $false
        $closeButton.Enabled = $false

        Write-LauncherLog -Message "Sicherung gestartet ($($targetInfo.RoleDescription) Tage) → $targetRoot"
        Set-Status -Text "Sicherung laeuft auf $targetRoot ..." -Color $accentColor -IsRunning $true

        Ensure-Directory -Path (Split-Path -Parent $logFile)
        Ensure-Directory -Path $targetRoot

        $robocopyArgs = @(
            '"' + $SourcePath + '"',
            '"' + $targetRoot + '"',
            '/MIR',
            '/R:3',
            '/W:5',
            '/MT:16',
            '/COPY:DAT',
            '/DCOPY:T',
            '/V',
            '/NP',
            '/LOG:"' + $logFile + '"'
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'robocopy.exe'
        $startInfo.Arguments = $robocopyArgs -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw 'Robocopy konnte nicht gestartet werden.'
        }

        $script:activeBackup = [PSCustomObject]@{
            Process = $process
            LogPath = $logFile
            Target  = $targetRoot
            Role    = $targetInfo.RoleDescription
            Stamp   = $targetInfo.TimestampLabel
        }

        $pollTimer.Start()
        $script:currentLogFile = $logFile
    }
    catch {
        $pollTimer.Stop()
        $script:activeBackup = $null
        $startButton.Enabled = $true
        $closeButton.Enabled = $true

        $message = Show-UiError -ErrorObject $_ -Fallback 'Die Sicherung konnte nicht gestartet werden.'
        Set-Status -Text 'Fehler beim Start.' -Color $errorColor -IsRunning:$false
        Write-LauncherLog -Message "Start fehlgeschlagen: $message"
    }
}

function Complete-Backup {
    if (-not $script:activeBackup) {
        return
    }

    $pollTimer.Stop()

    $process = $script:activeBackup.Process

    try {
        $process.WaitForExit()
    }
    catch {
        Write-LauncherLog -Message "Warten auf Robocopy fehlgeschlagen: $($_.Exception.Message)"
    }

    $exitCode = $null
    try {
        $exitCode = $process.ExitCode
    }
    catch {
        $exitCode = 16
    }
    finally {
        $process.Dispose()
    }

    $result = $script:activeBackup
    $script:activeBackup = $null

    $startButton.Enabled = $true
    $closeButton.Enabled = $true

    $logPath = $result.LogPath
    $target  = $result.Target

    $script:currentLogFile = $logPath
    $logTextBox.AppendText("Logdatei: $logPath`r`n")
    if ($result.Stamp) {
        $logTextBox.AppendText("Zeitstempel: $($result.Stamp)`r`n")
    }

    if ($exitCode -gt 7) {
        Set-Status -Text 'Backup mit Fehler beendet. Log pruefen.' -Color $errorColor -IsRunning:$false
        $errorMessage = "Robocopy meldet Fehler (Code $exitCode). Bitte Log ansehen."
        Show-ErrorDialog -Message $errorMessage
        $logTextBox.AppendText($errorMessage + "`r`n")
        $openLogButton.Enabled = $true
        $role = $result.Role
        Write-LauncherLog -Message "Sicherung ($role) mit Fehlercode $exitCode beendet."
        return
    }

    $role = $result.Role

    Set-Status -Text "Backup erfolgreich: $target" -Color $successColor -IsRunning:$false
    $openLogButton.Enabled = $true

    try {
        $logContent = Get-Content -LiteralPath $logPath -ErrorAction Stop
        $recentLines = $logContent | Select-Object -Last 200
        $logTextBox.AppendText(($recentLines -join [Environment]::NewLine) + [Environment]::NewLine)
    }
    catch {
        $message = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Log konnte nicht geladen werden.'
        $logTextBox.AppendText("$message`r`n")
        Write-LauncherLog -Message "Lesen des Logs fehlgeschlagen: $message"
    }

    Write-LauncherLog -Message "Sicherung ($role) erfolgreich abgeschlossen (Code $exitCode)."

    if ($shutdownCheckbox.Checked) {
        Set-Status -Text ($statusLabel.Text + ' | Herunterfahren wird gestartet.') -Color $successColor -IsRunning:$false
        try {
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s','/t','0'
        }
        catch {
            $message = Show-UiError -ErrorObject $_ -Fallback 'Herunterfahren konnte nicht gestartet werden.' -Title 'Herunterfahren fehlgeschlagen'
            Write-LauncherLog -Message "Herunterfahren fehlgeschlagen: $message"
        }
    }
}

$startButton.Add_Click({ Start-BackupRun })

$openLogButton.Add_Click({
    if ($script:currentLogFile -and (Test-Path -LiteralPath $script:currentLogFile)) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList $script:currentLogFile
    }
})

$closeButton.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($sender, $e)

    if ($script:activeBackup) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            'Die Sicherung laeuft noch. Bitte warten Sie, bis der Vorgang abgeschlossen ist.',
            'Winback Sicherung',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

Write-LauncherLog -Message 'Benutzeroberflaeche wird angezeigt'
[void]$form.ShowDialog()
Write-LauncherLog -Message 'Benutzeroberflaeche geschlossen'
}
catch {
    Write-LauncherLog -Message ("Unbehandelter Fehler: " + $_.Exception.Message)

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "Es ist ein unerwarteter Fehler aufgetreten: $($_.Exception.Message)`nWeitere Details finden Sie in '$script:LauncherLogPath'.",
            'Winback Sicherung',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Error "Unerwarteter Fehler: $($_.Exception.Message)"
        Start-Sleep -Seconds 8
    }
}
