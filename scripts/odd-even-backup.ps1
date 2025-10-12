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
            throw "Der Neustart des Skripts konnte nicht ausgelöst werden."
        }
    }
    catch {
        Write-LauncherLog -Message "Neustart fehlgeschlagen: $($_.Exception.Message)"

        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show(
                "Die Benutzeroberfläche konnte nicht gestartet werden. Bitte die Datei '$script:LauncherLogPath' prüfen.",
                'Winback Sicherung',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        catch {
            Write-Error "Die Benutzeroberfläche konnte nicht gestartet werden: $($_.Exception.Message)"
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
            throw "Der Pfad '$expanded' ist ungültig. Bitte einen absoluten Zielpfad angeben."
        }

        return [PSCustomObject]@{
            DriveRoot = $root
            BasePath  = $expanded
        }
    }

    if ($Config.ContainsKey('DriveLetter') -and $Config.DriveLetter) {
        $letter = $Config.DriveLetter.ToString().TrimEnd(':')

        if ([string]::IsNullOrWhiteSpace($letter)) {
            throw "Die Laufwerksangabe für $RoleDescription Tage enthält keinen gültigen Buchstaben."
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
            throw "Das Laufwerk für $RoleDescription Tage mit dem Namen '$($Config.VolumeLabel)' wurde nicht gefunden."
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

    throw "Konfiguration für $RoleDescription Tage ist unvollständig. Bitte entweder Path oder VolumeLabel/DriveLetter angeben."
}

function Get-TargetInfo {
    param(
        [Parameter(Mandatory)] [DateTime] $Date,
        [Parameter(Mandatory)] [hashtable] $EvenConfig,
        [Parameter(Mandatory)] [hashtable] $OddConfig,
        [bool] $Timestamped = $false
    )

    $isEvenDay = ($Date.Day % 2) -eq 0
    $roleDescription = if ($isEvenDay) { 'gerade' } else { 'ungerade' }
    $config = if ($isEvenDay) { $EvenConfig } else { $OddConfig }

    $resolved = Resolve-DriveRoot -Config $config -RoleDescription "$roleDescription"

    if ($Timestamped) {
        $stamp = $Date.ToString('yyyy-MM-dd_HHmmss')
        $destination = Join-Path -Path $resolved.BasePath -ChildPath $stamp
    }
    else {
        $destination = $resolved.BasePath
    }

    return [PSCustomObject]@{
        RoleDescription = $roleDescription
        DriveRoot       = $resolved.DriveRoot
        BasePath        = $resolved.BasePath
        DestinationPath = $destination
    }
}

function Invoke-Backup {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $LogPath
    )

    Ensure-Directory -Path (Split-Path -Parent $LogPath)
    Ensure-Directory -Path $Destination

    $robocopyArgs = @(
        '"' + $Source + '"',
        '"' + $Destination + '"',
        '/MIR',          # Mirror source to destination (adds/removes files as needed)
        '/R:3',          # Retry up to 3 times on failure
        '/W:5',          # Wait 5 seconds between retries
        '/MT:16',        # Use multithreading for speed
        '/COPY:DAT',     # Copy data, attributes, timestamps
        '/DCOPY:T',      # Copy directory timestamps
        '/V',            # Produce verbose output
        '/NP',           # Do not display progress percentage (cleaner log)
        '/LOG:"' + $LogPath + '"'
    )

    $robocopyCommand = "robocopy " + ($robocopyArgs -join ' ')
    Write-Host "Running: $robocopyCommand" -ForegroundColor Cyan

    $process = Start-Process -FilePath 'robocopy.exe' -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru
    return $process.ExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-ErrorDialog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Title = 'Backup-Fehler'
    )

    [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

$form = New-Object System.Windows.Forms.Form -Property @{
    Text            = 'Winback Sicherung'
    Size            = New-Object System.Drawing.Size(520, 420)
    FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    MaximizeBox     = $false
    StartPosition   = 'CenterScreen'
}

$evenDescription = Get-ConfigDescription -Config $EvenDayTargetConfig
$oddDescription  = Get-ConfigDescription -Config $OddDayTargetConfig

$infoLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $false
    Location = New-Object System.Drawing.Point(10, 10)
    Size     = New-Object System.Drawing.Size(480, 70)
    Text     = "Quelle: $SourcePath`r`nGerade Tage: $evenDescription`r`nUngerade Tage: $oddDescription"
}
$form.Controls.Add($infoLabel)

$statusLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize = $false
    Location = New-Object System.Drawing.Point(10, 90)
    Size     = New-Object System.Drawing.Size(480, 40)
    Font     = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    Text     = 'Bereit für Sicherung.'
}
$form.Controls.Add($statusLabel)

$logTextBox = New-Object System.Windows.Forms.TextBox -Property @{
    Multiline       = $true
    ScrollBars      = 'Vertical'
    ReadOnly        = $true
    Location        = New-Object System.Drawing.Point(10, 135)
    Size            = New-Object System.Drawing.Size(480, 190)
    Font            = New-Object System.Drawing.Font('Consolas', 9)
    BackColor       = [System.Drawing.Color]::White
}
$form.Controls.Add($logTextBox)

$shutdownCheckbox = New-Object System.Windows.Forms.CheckBox -Property @{
    Location = New-Object System.Drawing.Point(10, 335)
    Size     = New-Object System.Drawing.Size(320, 25)
    Text     = 'Nach erfolgreichem Backup herunterfahren'
}
$form.Controls.Add($shutdownCheckbox)

$startButton = New-Object System.Windows.Forms.Button -Property @{
    Text     = 'Backup starten'
    Location = New-Object System.Drawing.Point(10, 365)
    Size     = New-Object System.Drawing.Size(150, 30)
}
$form.Controls.Add($startButton)

$openLogButton = New-Object System.Windows.Forms.Button -Property @{
    Text     = 'Logdatei öffnen'
    Location = New-Object System.Drawing.Point(170, 365)
    Size     = New-Object System.Drawing.Size(150, 30)
    Enabled  = $false
}
$form.Controls.Add($openLogButton)

$closeButton = New-Object System.Windows.Forms.Button -Property @{
    Text     = 'Schließen'
    Location = New-Object System.Drawing.Point(340, 365)
    Size     = New-Object System.Drawing.Size(150, 30)
}
$form.Controls.Add($closeButton)

$backgroundWorker = New-Object System.ComponentModel.BackgroundWorker
$backgroundWorker.WorkerSupportsCancellation = $false

$script:currentLogFile = $null

function Start-BackupRun {
    $logTextBox.Clear()
    $openLogButton.Enabled = $false
    $statusLabel.ForeColor = [System.Drawing.Color]::FromKnownColor('ControlText')

    try {
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            throw "Der Quellordner '$SourcePath' wurde nicht gefunden. Bitte Konfiguration prüfen."
        }

        $today      = Get-Date
        $targetInfo = Get-TargetInfo -Date $today -EvenConfig $EvenDayTargetConfig -OddConfig $OddDayTargetConfig -Timestamped:$UseTimestampFolder

        if ($targetInfo.DriveRoot -and -not (Test-Path -LiteralPath $targetInfo.DriveRoot)) {
            throw "Das Laufwerk für $($targetInfo.RoleDescription) Tage ist nicht erreichbar. Bitte die passende USB-Festplatte anschließen."
        }

        $targetRoot = $targetInfo.DestinationPath
        $logFileName = "backup-" + $today.ToString('yyyy-MM-dd_HHmmss') + '.log'
        $logFile     = Join-Path -Path $LogDirectory -ChildPath $logFileName

        $statusLabel.Text = "Sicherung läuft auf $targetRoot ..."
        $startButton.Enabled = $false
        $closeButton.Enabled = $false

        $args = @{
            Source      = $SourcePath
            Destination = $targetRoot
            LogPath     = $logFile
            Role        = $targetInfo.RoleDescription
        }

        $backgroundWorker.RunWorkerAsync($args)
        $script:currentLogFile = $logFile
    }
    catch {
        $statusLabel.Text = 'Fehler beim Start.'
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        Show-ErrorDialog -Message $_.Exception.Message
        $startButton.Enabled = $true
        $closeButton.Enabled = $true
    }
}

$backgroundWorker.Add_DoWork({
    param($sender, $e)

    $arg = $e.Argument
    $e.Result = [PSCustomObject]@{
        ExitCode = Invoke-Backup -Source $arg.Source -Destination $arg.Destination -LogPath $arg.LogPath
        LogPath  = $arg.LogPath
        Target   = $arg.Destination
        Role     = $arg.Role
    }
})

$backgroundWorker.Add_RunWorkerCompleted({
    param($sender, $e)

    $startButton.Enabled = $true
    $closeButton.Enabled = $true

    if ($e.Error) {
        $statusLabel.Text = 'Backup fehlgeschlagen.'
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        Show-ErrorDialog -Message $e.Error.Exception.Message
        return
    }

    $result = $e.Result
    $logTextBox.AppendText("Logdatei: $($result.LogPath)`r`n")

    if ($result.ExitCode -gt 7) {
        $statusLabel.Text = 'Backup mit Fehler beendet. Log prüfen.'
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        Show-ErrorDialog -Message "Robocopy meldet Fehler (Code $($result.ExitCode)). Bitte Log ansehen."
        $openLogButton.Enabled = $true
        return
    }

    $statusLabel.Text = "Backup erfolgreich: $($result.Target)"
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    $openLogButton.Enabled = $true

    try {
        $logContent = Get-Content -LiteralPath $result.LogPath -ErrorAction Stop
        $recentLines = $logContent | Select-Object -Last 200
        $logTextBox.AppendText(($recentLines -join [Environment]::NewLine) + [Environment]::NewLine)
    }
    catch {
        $logTextBox.AppendText("Log konnte nicht geladen werden: $($_.Exception.Message)`r`n")
    }

    if ($shutdownCheckbox.Checked) {
        $statusLabel.Text += ' | Herunterfahren wird gestartet.'
        try {
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s','/t','0'
        }
        catch {
            Show-ErrorDialog -Message "Herunterfahren konnte nicht gestartet werden: $($_.Exception.Message)"
        }
    }
})

$startButton.Add_Click({ Start-BackupRun })

$openLogButton.Add_Click({
    if ($script:currentLogFile -and (Test-Path -LiteralPath $script:currentLogFile)) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList $script:currentLogFile
    }
})

$closeButton.Add_Click({ $form.Close() })

Write-LauncherLog -Message 'Benutzeroberfläche wird angezeigt'
[void]$form.ShowDialog()
Write-LauncherLog -Message 'Benutzeroberfläche geschlossen'
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
