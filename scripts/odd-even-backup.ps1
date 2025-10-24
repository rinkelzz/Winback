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

$script:LogRoot = $null
$script:LauncherLogPath = $null

function Initialize-LogStorage {
    param(
        [switch] $Force
    )

    if (-not $Force -and $script:LogRoot -and $script:LauncherLogPath) {
        return
    }

    $candidateParents = @()

    $documentsPath = [Environment]::GetFolderPath('MyDocuments')
    if (-not [string]::IsNullOrWhiteSpace($documentsPath)) {
        $candidateParents += $documentsPath
    }

    $localAppDataPath = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not [string]::IsNullOrWhiteSpace($localAppDataPath)) {
        $candidateParents += $localAppDataPath
    }

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidateParents += $PSScriptRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $candidateParents += $env:TEMP
    }

    $lastError = $null
    $newRoot = $null

    foreach ($parent in $candidateParents | Select-Object -Unique) {
        try {
            $candidate = Join-Path -Path $parent -ChildPath 'WinbackLogs'
            [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
            $newRoot = $candidate
            break
        }
        catch {
            $lastError = $_
        }
    }

    if (-not $newRoot) {
        $message = if ($lastError) { $lastError.Exception.Message } else { 'Unbekannter Fehler' }
        throw "Die Protokollablage konnte nicht vorbereitet werden: $message"
    }

    $script:LogRoot = $newRoot
    $script:LauncherLogPath = Join-Path -Path $script:LogRoot -ChildPath 'launcher.log'
}

try {
    Initialize-LogStorage
}
catch {
    $message = "Die Protokollablage konnte nicht vorbereitet werden: $($_.Exception.Message)"

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "$message`nBitte pruefen Sie Schreibrechte auf Dokumente-, AppData- oder Temp-Ordner.",
            'Backup by RinkelTech',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Error $message
        Start-Sleep -Seconds 8
    }

    return
}

function Write-LauncherLog {
    param(
        [Parameter(Mandatory)] [string] $Message
    )

    Initialize-LogStorage

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $script:LauncherLogPath -Value "[$timestamp] $Message" -Encoding UTF8
    }
    catch {
        try {
            Initialize-LogStorage -Force
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Add-Content -LiteralPath $script:LauncherLogPath -Value "[$timestamp] $Message" -Encoding UTF8
        }
        catch {
            Write-Warning "Konnte Startprotokoll nicht schreiben: $($_.Exception.Message)"
        }
    }
}

Write-LauncherLog -Message 'Skriptstart'

$script:ApplicationTitleBase = 'Backup by RinkelTech'
$script:ApplicationTitle = "$($script:ApplicationTitleBase) license for"

$script:StaRelaunchMarker = '--winback-sta'
$script:LaunchedViaStaRelaunch = $false

if ($args -contains $script:StaRelaunchMarker) {
    $script:LaunchedViaStaRelaunch = $true
    $args = $args | Where-Object { $_ -ne $script:StaRelaunchMarker }
}

try {
    $currentApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()
}
catch {
    $currentApartmentState = [System.Threading.ApartmentState]::Unknown
}

if (-not $script:LaunchedViaStaRelaunch -and $currentApartmentState -ne [System.Threading.ApartmentState]::STA) {
    Write-LauncherLog -Message 'Neustart mit STA-Anforderung'

    try {
        $powerShellPath = (Get-Command -Name 'powershell.exe' -ErrorAction Stop).Source
        $psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{
            FileName         = $powerShellPath
            Arguments        = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" $($script:StaRelaunchMarker)"
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
                $script:ApplicationTitle,
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
# List of backup sources. Each entry requires a SourcePath and can optionally
# specify TargetSubPath to control the relative folder name that will be
# created below the target location. When TargetSubPath is omitted, the script
# uses the name of the source folder.
$BackupItems = @(
    @{
        SourcePath    = "C:\\Path\\To\\Folder"
        TargetSubPath = 'Folder'
    }
)

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

# Optional: company name appended to the window title after "license for".
$LicenseCompanyName = ''

# Optional: set to $true to keep a timestamped subfolder per run instead of mirroring.
$UseTimestampFolder = $false

# Timestamp format for created folders when $UseTimestampFolder is enabled. Invalid
# characters for Windows paths are automatically replaced with underscores.
$TimestampFolderFormat = 'yyyy_MM_dd-HH:mm'

# Optional: delete timestamped backup folders older than the specified number of days.
# Applies only when $UseTimestampFolder is $true. Set to 0 or $null to disable cleanup.
$TimestampRetentionDays = 0

# Folder to store Robocopy logs. Will be created if it doesn't exist.
$LogDirectory = $script:LogRoot

# Optional: send error reports with log files when a backup fails. Configure SMTP
# connection details if enabled.
$EmailErrorReportsEnabled = $false
$EmailSmtpServer         = ''
$EmailSmtpPort           = 587
$EmailUseSsl             = $true
$EmailFromAddress        = ''
$EmailToAddresses        = 'backup@rinkel.tech'
$EmailSubjectPrefix      = 'Backup Fehler'
$EmailSmtpUsername       = ''
$EmailSmtpPassword       = ''
#endregion ---------------------------------------------------------------------

function Sanitize-PathSegment {
    param(
        [Parameter(Mandatory)] [string] $Value
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $Value.ToCharArray()) {
        if ($invalidChars -contains $char) {
            [void]$builder.Append('_')
        }
        else {
            [void]$builder.Append($char)
        }
    }

    if ($builder.Length -eq 0) {
        return 'Backup'
    }

    return $builder.ToString()
}

function Get-BackupItemSourceList {
    param(
        [Parameter()] [object[]] $Items
    )

    $result = New-Object System.Collections.Generic.List[string]

    foreach ($item in $Items) {
        if (-not $item) {
            continue
        }

        if ($item -is [hashtable] -and $item.ContainsKey('SourcePath') -and $item.SourcePath) {
            $result.Add($item.SourcePath.ToString())
        }
    }

    if ($result.Count -eq 0) {
        $result.Add('Keine Quellen konfiguriert.')
    }

    return $result
}

function Resolve-BackupQueue {
    param(
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [string] $TargetRoot
    )

    $queue = New-Object System.Collections.Generic.List[object]
    $index = 0

    foreach ($item in $Items) {
        if (-not $item) {
            continue
        }

        if ($item -isnot [hashtable]) {
            throw 'Ein Sicherungseintrag muss als Hashtable mit SourcePath angegeben werden.'
        }

        if (-not $item.ContainsKey('SourcePath') -or [string]::IsNullOrWhiteSpace($item.SourcePath)) {
            throw 'Ein Sicherungseintrag besitzt keinen gueltigen SourcePath.'
        }

        $source = [Environment]::ExpandEnvironmentVariables($item.SourcePath.ToString())

        if (-not (Test-Path -LiteralPath $source)) {
            throw "Der Quellordner '$source' wurde nicht gefunden. Bitte Konfiguration pruefen."
        }

        $targetSegment = $null

        if ($item.ContainsKey('TargetSubPath') -and -not [string]::IsNullOrWhiteSpace($item.TargetSubPath)) {
            $targetSegment = Sanitize-PathSegment -Value $item.TargetSubPath.ToString()
        }
        else {
            $leaf = Split-Path -Path $source -Leaf

            if ([string]::IsNullOrWhiteSpace($leaf)) {
                throw "Fuer die Quelle '$source' muss TargetSubPath gesetzt werden."
            }

            $targetSegment = Sanitize-PathSegment -Value $leaf
        }

        $destination = Join-Path -Path $TargetRoot -ChildPath $targetSegment

        $queue.Add([PSCustomObject]@{
            SourcePath      = $source
            DestinationPath = $destination
            DisplayName     = $targetSegment
            Index           = $index
        })

        $index++
    }

    if ($queue.Count -eq 0) {
        throw 'Es wurde kein gueltiger Sicherungseintrag konfiguriert.'
    }

    return $queue
}

$companyNameForTitle = if ($null -ne $LicenseCompanyName) { $LicenseCompanyName.Trim() } else { '' }
if ([string]::IsNullOrWhiteSpace($companyNameForTitle)) {
    $script:ApplicationTitle = "$($script:ApplicationTitleBase) license for"
}
else {
    $script:ApplicationTitle = "$($script:ApplicationTitleBase) license for $companyNameForTitle"
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Format-ByteSize {
    param(
        [Parameter()] [Nullable[long]] $Value
    )

    if (-not $Value.HasValue -or $Value.Value -lt 0) {
        return 'unbekannt'
    }

    $units = @('Bytes','KB','MB','GB','TB','PB')
    $size  = [double]$Value.Value
    $index = 0

    while ($size -ge 1024 -and $index -lt $units.Count - 1) {
        $size /= 1024
        $index++
    }

    return ('{0:N1} {1}' -f $size, $units[$index])
}

function Find-DriveByVolumeLabel {
    param(
        [Parameter(Mandatory)] [string] $Label
    )

    try {
        $drives = [System.IO.DriveInfo]::GetDrives()
    }
    catch {
        return $null
    }

    foreach ($drive in $drives) {
        try {
            if (-not $drive.IsReady) {
                continue
            }

            $volumeLabel = $drive.VolumeLabel

            if ([string]::IsNullOrWhiteSpace($volumeLabel)) {
                continue
            }

            if ($volumeLabel.Equals($Label, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $drive
            }
        }
        catch {
            continue
        }
    }

    return $null
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

function Get-EmailRecipients {
    param(
        [Parameter()] [string] $Addresses
    )

    if ([string]::IsNullOrWhiteSpace($Addresses)) {
        return @()
    }

    return $Addresses -split '[;,]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
}

function Send-ErrorReport {
    param(
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [string[]] $Attachments = @()
    )

    if (-not $EmailErrorReportsEnabled) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($EmailSmtpServer) -or [string]::IsNullOrWhiteSpace($EmailFromAddress)) {
        Write-LauncherLog -Message 'E-Mail-Benachrichtigung nicht moeglich: SMTP-Server oder Absender fehlt.'
        return
    }

    $recipients = Get-EmailRecipients -Addresses $EmailToAddresses

    if ($recipients.Count -eq 0) {
        Write-LauncherLog -Message 'E-Mail-Benachrichtigung nicht moeglich: Keine gueltigen Empfaenger.'
        return
    }

    try {
        $client = New-Object System.Net.Mail.SmtpClient($EmailSmtpServer, [int]$EmailSmtpPort)
        $client.EnableSsl = [bool]$EmailUseSsl

        if (-not [string]::IsNullOrWhiteSpace($EmailSmtpUsername)) {
            $client.Credentials = New-Object System.Net.NetworkCredential($EmailSmtpUsername, $EmailSmtpPassword)
        }

        $message = New-Object System.Net.Mail.MailMessage
        $message.From = $EmailFromAddress

        foreach ($address in $recipients) {
            [void]$message.To.Add($address)
        }

        $message.Subject = $Subject
        $message.Body    = $Body

        $attachmentsToDispose = @()

        foreach ($path in $Attachments) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $path)) {
                Write-LauncherLog -Message "E-Mail-Anhang fehlt: $path"
                continue
            }

            try {
                $attachment = New-Object System.Net.Mail.Attachment($path)
                $attachmentsToDispose += $attachment
                [void]$message.Attachments.Add($attachment)
            }
            catch {
                $errorMessage = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Anhang konnte nicht hinzugefuegt werden.'
                Write-LauncherLog -Message "E-Mail-Anhang konnte nicht hinzugefuegt werden: $errorMessage"
            }
        }

        try {
            $client.Send($message)
            Write-LauncherLog -Message 'Fehlerbenachrichtigung per E-Mail versendet.'
        }
        finally {
            foreach ($item in $attachmentsToDispose) {
                $item.Dispose()
            }

            $message.Dispose()
            $client.Dispose()
        }
    }
    catch {
        $errorMessage = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'E-Mail-Versand fehlgeschlagen.'
        Write-LauncherLog -Message "E-Mail-Versand fehlgeschlagen: $errorMessage"
    }
}

function Submit-ErrorReport {
    param(
        [Parameter(Mandatory)] [string] $Context,
        [string] $Details,
        [string[]] $Attachments = @()
    )

    if (-not $EmailErrorReportsEnabled) {
        return
    }

    $subject = if ([string]::IsNullOrWhiteSpace($EmailSubjectPrefix)) {
        "Backup-Fehler: $Context"
    }
    else {
        "$EmailSubjectPrefix - $Context"
    }

    $bodyBuilder = New-Object System.Text.StringBuilder
    [void]$bodyBuilder.AppendLine("Zeitpunkt: " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    [void]$bodyBuilder.AppendLine("Computer: " + [Environment]::MachineName)
    [void]$bodyBuilder.AppendLine("Kontext: $Context")

    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        [void]$bodyBuilder.AppendLine('')
        [void]$bodyBuilder.AppendLine('Details:')
        [void]$bodyBuilder.AppendLine($Details)
    }

    $safeAttachments = @()

    foreach ($item in ($Attachments | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and (Test-Path -LiteralPath $item)) {
            $safeAttachments += $item
        }
    }

    Send-ErrorReport -Subject $subject -Body $bodyBuilder.ToString() -Attachments $safeAttachments
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

function Get-DriveCapacityStatus {
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $RoleDescription
    )

    $result = [PSCustomObject]@{
        Text       = 'Nicht konfiguriert.'
        IsAvailable = $false
    }

    if (-not $Config) {
        return $result
    }

    try {
        if ($Config.ContainsKey('Path') -and $Config.Path) {
            $expanded = [Environment]::ExpandEnvironmentVariables($Config.Path)
            $root = [System.IO.Path]::GetPathRoot($expanded)

            if (-not $root) {
                $result.Text = "Pfad fuer $RoleDescription Tage ungueltig."
                return $result
            }

            $driveInfo = New-Object System.IO.DriveInfo($root)

            if (-not $driveInfo.IsReady) {
                $result.Text = "Laufwerk $root nicht verfuegbar."
                return $result
            }

            $result.Text = "Laufwerk $root: Frei " + (Format-ByteSize $driveInfo.AvailableFreeSpace) + ' von ' + (Format-ByteSize $driveInfo.TotalSize)
            $result.IsAvailable = $true
            return $result
        }

        if ($Config.ContainsKey('VolumeLabel') -and $Config.VolumeLabel) {
            $drive = Find-DriveByVolumeLabel -Label $Config.VolumeLabel

            if (-not $drive) {
                $result.Text = "Laufwerk '$($Config.VolumeLabel)' nicht verbunden."
                return $result
            }

            $root = $drive.RootDirectory.FullName
            $result.Text = "Laufwerk $root: Frei " + (Format-ByteSize $drive.AvailableFreeSpace) + ' von ' + (Format-ByteSize $drive.TotalSize)
            $result.IsAvailable = $true
            return $result
        }

        if ($Config.ContainsKey('DriveLetter') -and $Config.DriveLetter) {
            $letter = $Config.DriveLetter.ToString().TrimEnd(':')

            if ([string]::IsNullOrWhiteSpace($letter)) {
                $result.Text = "Laufwerksbuchstabe fuer $RoleDescription Tage ungueltig."
                return $result
            }

            $root = "{0}:\" -f $letter.ToUpper()
            $driveInfo = New-Object System.IO.DriveInfo($root)

            if (-not $driveInfo.IsReady) {
                $result.Text = "Laufwerk $root nicht verfuegbar."
                return $result
            }

            $result.Text = "Laufwerk $root: Frei " + (Format-ByteSize $driveInfo.AvailableFreeSpace) + ' von ' + (Format-ByteSize $driveInfo.TotalSize)
            $result.IsAvailable = $true
            return $result
        }
    }
    catch {
        $message = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Speicherabfrage fehlgeschlagen.'
        $result.Text = $message
        return $result
    }

    return $result
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

        $driveInfo = New-Object System.IO.DriveInfo($root)

        if (-not $driveInfo.IsReady) {
            throw "Das Laufwerk '$root' ist nicht bereit oder nicht verbunden."
        }

        return [PSCustomObject]@{
            DriveRoot = $root
            BasePath  = $expanded
            FreeBytes = $driveInfo.AvailableFreeSpace
            TotalBytes = $driveInfo.TotalSize
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

        $driveInfo = New-Object System.IO.DriveInfo($driveRoot)

        if (-not $driveInfo.IsReady) {
            throw "Das Laufwerk fuer $RoleDescription Tage ($driveRoot) ist nicht bereit oder nicht verbunden."
        }

        return [PSCustomObject]@{
            DriveRoot = $driveRoot
            BasePath  = $basePath
            FreeBytes = $driveInfo.AvailableFreeSpace
            TotalBytes = $driveInfo.TotalSize
        }
    }

    if ($Config.ContainsKey('VolumeLabel') -and $Config.VolumeLabel) {
        $drive = Find-DriveByVolumeLabel -Label $Config.VolumeLabel

        if (-not $drive) {
            throw "Das Laufwerk fuer $RoleDescription Tage mit dem Namen '$($Config.VolumeLabel)' wurde nicht gefunden."
        }

        $driveRoot = $drive.RootDirectory.FullName

        if ($Config.ContainsKey('RelativePath') -and $Config.RelativePath) {
            $basePath = Join-Path -Path $driveRoot -ChildPath $Config.RelativePath
        }
        else {
            $basePath = $driveRoot
        }

        return [PSCustomObject]@{
            DriveRoot = $driveRoot
            BasePath  = $basePath
            FreeBytes = [long]$drive.AvailableFreeSpace
            TotalBytes = [long]$drive.TotalSize
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

function Invoke-TimestampRetention {
    param(
        [Parameter(Mandatory)] [string] $BasePath,
        [Parameter(Mandatory)] [int] $RetentionDays,
        [string[]] $ProtectedNames = @()
    )

    $result = [PSCustomObject]@{
        Removed = New-Object System.Collections.ArrayList
        Failed  = New-Object System.Collections.ArrayList
    }

    if ($RetentionDays -le 0 -or -not (Test-Path -LiteralPath $BasePath)) {
        return $result
    }

    try {
        $threshold = (Get-Date).AddDays(-1 * $RetentionDays)
        $candidates = Get-ChildItem -LiteralPath $BasePath -Directory -ErrorAction Stop

        $protectedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $ProtectedNames) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$protectedSet.Add($name.Trim())
            }
        }

        foreach ($entry in $candidates) {
            if ($protectedSet.Contains($entry.Name)) {
                Write-LauncherLog -Message "Bereinigung uebersprungen fuer aktives Verzeichnis: $($entry.FullName)"
                continue
            }

            $ageMarkers = @()

            if ($entry.CreationTime -and $entry.CreationTime -gt [DateTime]::MinValue) {
                $ageMarkers += $entry.CreationTime
            }

            if ($entry.LastWriteTime -and $entry.LastWriteTime -gt [DateTime]::MinValue) {
                $ageMarkers += $entry.LastWriteTime
            }

            if ($ageMarkers.Count -eq 0) {
                continue
            }

            $ageMarker = ($ageMarkers | Sort-Object -Descending | Select-Object -First 1)

            if ($ageMarker -ge $threshold) {
                continue
            }

            try {
                Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
                [void]$result.Removed.Add($entry.Name)
                Write-LauncherLog -Message "Altes Sicherungsverzeichnis entfernt: $($entry.FullName)"
            }
            catch {
                $message = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Ordner konnte nicht geloescht werden.'
                [void]$result.Failed.Add("$($entry.Name): $message")
                Write-LauncherLog -Message "Aufraeumen fehlgeschlagen fuer $($entry.FullName): $message"
            }
        }
    }
    catch {
        $message = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Bereinigung fehlgeschlagen.'
        [void]$result.Failed.Add($message)
        Write-LauncherLog -Message "Bereinigung der Zeitstempel-Verzeichnisse fehlgeschlagen: $message"
    }

    return $result
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
        UsingTimestamp  = $Timestamped
        DriveFreeBytes  = $resolved.FreeBytes
        DriveTotalBytes = $resolved.TotalBytes
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
    Text            = $script:ApplicationTitle
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
    RowCount    = 5
    BackColor   = $backgroundCol
    Padding     = New-Object System.Windows.Forms.Padding(14)
}
$tableLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
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

$sourcesForDisplay = Get-BackupItemSourceList -Items $BackupItems | ForEach-Object { "• $_" }
$sourcesText = ($sourcesForDisplay -join "`r`n")

$infoLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize     = $true
    Dock         = 'Top'
    MaximumSize  = New-Object System.Drawing.Size(520, 0)
    Padding      = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    Text         = "Quellen:`r`n$sourcesText`r`n`r`nGerade Tage: $evenDescription`r`nUngerade Tage: $oddDescription"
    ForeColor    = $neutralColor
}
$headerPanel.Controls.Add($infoLabel)
$tableLayout.Controls.Add($headerPanel, 0, 0)

$capacityPanel = New-Object System.Windows.Forms.Panel -Property @{
    BackColor = $surfaceColor
    AutoSize  = $true
    Dock      = 'Top'
    Padding   = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    Margin    = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
}

$capacityCaption = New-Object System.Windows.Forms.Label -Property @{
    Text     = 'Speicherkapazitaet'
    AutoSize = $true
    Font     = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    ForeColor = $accentColor
    Dock     = 'Top'
}
$capacityPanel.Controls.Add($capacityCaption)

$capacityTable = New-Object System.Windows.Forms.TableLayoutPanel -Property @{
    ColumnCount = 2
    AutoSize    = $true
    Dock        = 'Top'
    BackColor   = [System.Drawing.Color]::Transparent
    Margin      = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
}
$capacityTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$capacityTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$evenDriveLabel = New-Object System.Windows.Forms.Label -Property @{
    Text      = 'Gerade Tage'
    AutoSize  = $true
    ForeColor = $neutralColor
    Dock      = 'Fill'
    Padding   = New-Object System.Windows.Forms.Padding(0, 0, 18, 6)
}
$capacityTable.Controls.Add($evenDriveLabel, 0, 0)

$evenDriveStatusLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize  = $true
    ForeColor = $neutralColor
    Dock      = 'Fill'
    Padding   = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    Text      = 'Keine Daten verfuegbar.'
}
$capacityTable.Controls.Add($evenDriveStatusLabel, 1, 0)

$oddDriveLabel = New-Object System.Windows.Forms.Label -Property @{
    Text      = 'Ungerade Tage'
    AutoSize  = $true
    ForeColor = $neutralColor
    Dock      = 'Fill'
    Padding   = New-Object System.Windows.Forms.Padding(0, 0, 18, 0)
}
$capacityTable.Controls.Add($oddDriveLabel, 0, 1)

$oddDriveStatusLabel = New-Object System.Windows.Forms.Label -Property @{
    AutoSize  = $true
    ForeColor = $neutralColor
    Dock      = 'Fill'
    Text      = 'Keine Daten verfuegbar.'
}
$capacityTable.Controls.Add($oddDriveStatusLabel, 1, 1)

$capacityPanel.Controls.Add($capacityTable)
$tableLayout.Controls.Add($capacityPanel, 0, 1)

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

$tableLayout.Controls.Add($statusPanel, 0, 2)

$script:updateCapacityDisplay = {
    $evenStatus = Get-DriveCapacityStatus -Config $EvenDayTargetConfig -RoleDescription 'gerade'
    $evenDriveStatusLabel.Text = $evenStatus.Text
    $evenDriveStatusLabel.ForeColor = if ($evenStatus.IsAvailable) { $neutralColor } else { $errorColor }

    $oddStatus = Get-DriveCapacityStatus -Config $OddDayTargetConfig -RoleDescription 'ungerade'
    $oddDriveStatusLabel.Text = $oddStatus.Text
    $oddDriveStatusLabel.ForeColor = if ($oddStatus.IsAvailable) { $neutralColor } else { $errorColor }
}

&$script:updateCapacityDisplay

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
$tableLayout.Controls.Add($logGroup, 0, 3)

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
$tableLayout.Controls.Add($footerLayout, 0, 4)

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
    $script:currentLogFile = $null

    if ($script:updateCapacityDisplay) {
        &$script:updateCapacityDisplay
    }

    try {
        if ($script:activeBackup) {
            Write-LauncherLog -Message 'Sicherung bereits aktiv, Start ignoriert.'
            return
        }

        Set-Status -Text 'Pruefe Pfade und Laufwerke ...' -Color $accentColor -IsRunning $true

        $today      = Get-Date
        $targetInfo = Get-TargetInfo -Date $today -EvenConfig $EvenDayTargetConfig -OddConfig $OddDayTargetConfig -Timestamped:$UseTimestampFolder -TimestampFormat $TimestampFolderFormat

        if ($targetInfo.DriveRoot -and -not (Test-Path -LiteralPath $targetInfo.DriveRoot)) {
            throw "Das Laufwerk fuer $($targetInfo.RoleDescription) Tage ist nicht erreichbar. Bitte die passende USB-Festplatte anschliessen."
        }

        $targetRoot  = $targetInfo.DestinationPath
        $logFileName = "backup-" + $today.ToString('yyyy-MM-dd_HHmmss') + '.log'
        $logFile     = Join-Path -Path $LogDirectory -ChildPath $logFileName

        Ensure-Directory -Path (Split-Path -Parent $logFile)
        Ensure-Directory -Path $targetInfo.BasePath
        Ensure-Directory -Path $targetRoot

        $queue = Resolve-BackupQueue -Items $BackupItems -TargetRoot $targetRoot

        $logTextBox.AppendText("Ziel ($($targetInfo.RoleDescription) Tage): $targetRoot`r`n")
        if ($targetInfo.TimestampLabel) {
            $logTextBox.AppendText("Zeitstempel: $($targetInfo.TimestampLabel)`r`n")
        }
        if ($null -ne $targetInfo.DriveFreeBytes -and $null -ne $targetInfo.DriveTotalBytes) {
            $logTextBox.AppendText("Freier Speicher: " + (Format-ByteSize $targetInfo.DriveFreeBytes) + ' von ' + (Format-ByteSize $targetInfo.DriveTotalBytes) + "`r`n")
        }
        $logTextBox.AppendText("Robocopy-Protokoll: $logFile`r`n")
        $logTextBox.AppendText("Sicherungsquellen:`r`n")
        foreach ($task in $queue) {
            $logTextBox.AppendText("  [$([int]$task.Index + 1)] $($task.SourcePath) → $($task.DestinationPath)`r`n")
        }
        $logTextBox.AppendText("`r`n")

        $startButton.Enabled = $false
        $closeButton.Enabled = $false

        Write-LauncherLog -Message "Sicherung gestartet ($($targetInfo.RoleDescription) Tage) → $targetRoot ($($queue.Count) Quellen)"
        Set-Status -Text "Sicherung laeuft auf $targetRoot ..." -Color $accentColor -IsRunning $true

        $script:activeBackup = [PSCustomObject]@{
            Process       = $null
            LogPath       = $logFile
            Target        = $targetRoot
            Role          = $targetInfo.RoleDescription
            Stamp         = $targetInfo.TimestampLabel
            Base          = $targetInfo.BasePath
            TimestampMode = $targetInfo.UsingTimestamp
            FolderName    = if ($targetInfo.UsingTimestamp) { [System.IO.Path]::GetFileName($targetRoot) } else { $null }
            Queue         = $queue
            CurrentIndex  = -1
            CurrentTask   = $null
        }

        $script:currentLogFile = $logFile

        Start-NextBackupTask
    }
    catch {
        $pollTimer.Stop()
        $script:activeBackup = $null
        $startButton.Enabled = $true
        $closeButton.Enabled = $true

        $message = Show-UiError -ErrorObject $_ -Fallback 'Die Sicherung konnte nicht gestartet werden.'
        Set-Status -Text 'Fehler beim Start.' -Color $errorColor -IsRunning:$false
        Write-LauncherLog -Message "Start fehlgeschlagen: $message"

        if ($script:updateCapacityDisplay) {
            &$script:updateCapacityDisplay
        }

        $attachments = @()
        if ($script:currentLogFile -and (Test-Path -LiteralPath $script:currentLogFile)) {
            $attachments += $script:currentLogFile
        }
        if (Test-Path -LiteralPath $script:LauncherLogPath) {
            $attachments += $script:LauncherLogPath
        }

        Submit-ErrorReport -Context 'Start der Sicherung' -Details $message -Attachments $attachments
    }
}

function Start-NextBackupTask {
    if (-not $script:activeBackup) {
        return
    }

    $queue = $script:activeBackup.Queue

    if (-not $queue -or $queue.Count -eq 0) {
        Finalize-BackupRun -Success $true -ExitCode 0
        return
    }

    $nextIndex = $script:activeBackup.CurrentIndex + 1

    if ($nextIndex -ge $queue.Count) {
        Finalize-BackupRun -Success $true -ExitCode 0
        return
    }

    $task = $queue[$nextIndex]
    $script:activeBackup.CurrentIndex = $nextIndex
    $script:activeBackup.CurrentTask = $task

    $logPath = $script:activeBackup.LogPath
    $target  = $script:activeBackup.Target

    $logSwitch = if ($nextIndex -eq 0) { '/LOG:"' + $logPath + '"' } else { '/LOG+:"' + $logPath + '"' }

    $robocopyArgs = @(
        '"' + $task.SourcePath + '"',
        '"' + $task.DestinationPath + '"',
        '/MIR',
        '/R:3',
        '/W:5',
        '/MT:16',
        '/COPY:DAT',
        '/DCOPY:T',
        '/V',
        '/NP',
        $logSwitch
    )

    $logTextBox.AppendText("Starte Sicherung [$($nextIndex + 1)/$($queue.Count)]: $($task.SourcePath) → $($task.DestinationPath)`r`n")
    Write-LauncherLog -Message "Robocopy gestartet (#$($nextIndex + 1)): $($task.SourcePath) → $($task.DestinationPath)"

    Ensure-Directory -Path $task.DestinationPath

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

    $script:activeBackup.Process = $process
    Set-Status -Text "Sicherung laeuft auf $target – $($task.DisplayName)" -Color $accentColor -IsRunning $true
    $pollTimer.Start()
}

function Complete-Backup {
    if (-not $script:activeBackup) {
        return
    }

    $pollTimer.Stop()

    $process = $script:activeBackup.Process

    if (-not $process) {
        return
    }

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

    $task   = $script:activeBackup.CurrentTask
    $index  = $script:activeBackup.CurrentIndex
    $queue  = $script:activeBackup.Queue
    $total  = if ($queue) { $queue.Count } else { 0 }

    $script:activeBackup.Process = $null
    $script:activeBackup.CurrentTask = $null

    $logTextBox.AppendText("Beendet [$($index + 1)/$total] – Robocopy-Code: $exitCode`r`n")
    Write-LauncherLog -Message "Robocopy beendet (#$($index + 1)) mit Code $exitCode"

    if ($exitCode -gt 7) {
        $details = if ($task) { "Robocopy meldet Fehler (Code $exitCode) bei '$($task.SourcePath)' → '$($task.DestinationPath)'." } else { "Robocopy meldet Fehler (Code $exitCode)." }
        Finalize-BackupRun -Success $false -ErrorMessage $details -ExitCode $exitCode -FailedTask $task
        return
    }

    if ($total -gt 0 -and $index -lt ($total - 1)) {
        try {
            Start-NextBackupTask
        }
        catch {
            $message = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Die Sicherung konnte nicht fortgesetzt werden.'
            Finalize-BackupRun -Success $false -ErrorMessage $message -ExitCode 16 -FailedTask $task
        }
        return
    }

    Finalize-BackupRun -Success $true -ExitCode $exitCode
}

function Finalize-BackupRun {
    param(
        [Parameter(Mandatory)] [bool] $Success,
        [string] $ErrorMessage,
        [int] $ExitCode = 0,
        $FailedTask = $null
    )

    if (-not $script:activeBackup) {
        return
    }

    $result = $script:activeBackup
    $script:activeBackup = $null

    $startButton.Enabled = $true
    $closeButton.Enabled = $true

    $logPath = $result.LogPath
    $target  = $result.Target

    $script:currentLogFile = $logPath

    if ($result.Stamp) {
        $logTextBox.AppendText("Zeitstempel: $($result.Stamp)`r`n")
    }

    if ($logPath) {
        $logTextBox.AppendText("Logdatei: $logPath`r`n")
    }

    $hasLog = $false
    if ($logPath -and (Test-Path -LiteralPath $logPath)) {
        $hasLog = $true
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
    }
    else {
        $openLogButton.Enabled = $false
    }

    if (-not $Success) {
        $displayMessage = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { "Robocopy meldet Fehler (Code $ExitCode). Bitte Log ansehen." } else { $ErrorMessage }
        Set-Status -Text 'Backup mit Fehler beendet. Log pruefen.' -Color $errorColor -IsRunning:$false
        Show-ErrorDialog -Message $displayMessage
        $logTextBox.AppendText($displayMessage + "`r`n")

        $role = $result.Role
        Write-LauncherLog -Message "Sicherung ($role) mit Fehlercode $ExitCode beendet."

        if ($script:updateCapacityDisplay) {
            &$script:updateCapacityDisplay
        }

        $attachments = @()
        if ($hasLog) {
            $attachments += $logPath
        }
        if (Test-Path -LiteralPath $script:LauncherLogPath) {
            $attachments += $script:LauncherLogPath
        }

        $context = if ($FailedTask) { "Robocopy Fehlercode $ExitCode (" + $FailedTask.DisplayName + ')'} else { "Robocopy Fehlercode $ExitCode" }
        Submit-ErrorReport -Context $context -Details $displayMessage -Attachments $attachments

        return
    }

    $role = $result.Role

    Set-Status -Text "Backup erfolgreich: $target" -Color $successColor -IsRunning:$false

    if ($result.TimestampMode) {
        try {
            $now = Get-Date
            [System.IO.Directory]::SetCreationTime($target, $now)
            [System.IO.Directory]::SetLastWriteTime($target, $now)
            Write-LauncherLog -Message "Zeitstempel fuer Ordner aktualisiert: $target"
        }
        catch {
            $message = Get-FriendlyErrorMessage -ErrorObject $_ -Fallback 'Aktualisieren der Zeitstempel fehlgeschlagen.'
            Write-LauncherLog -Message "Zeitstempel des Sicherungsverzeichnisses konnten nicht aktualisiert werden: $message"
        }
    }

    Write-LauncherLog -Message "Sicherung ($role) erfolgreich abgeschlossen (Code $ExitCode)."

    if ($result.TimestampMode -and $TimestampRetentionDays -gt 0) {
        $logTextBox.AppendText("Starte Bereinigung fuer Ordner aelter als $TimestampRetentionDays Tage ...`r`n")
        $protected = @()
        if ($result.FolderName) {
            $protected += $result.FolderName
        }
        $cleanupResult = Invoke-TimestampRetention -BasePath $result.Base -RetentionDays $TimestampRetentionDays -ProtectedNames $protected

        if ($cleanupResult.Removed.Count -gt 0) {
            foreach ($folder in $cleanupResult.Removed) {
                $logTextBox.AppendText("Entfernt: $folder`r`n")
            }
        }
        else {
            $logTextBox.AppendText("Keine alten Ordner zum Entfernen gefunden.`r`n")
        }

        if ($cleanupResult.Failed.Count -gt 0) {
            foreach ($item in $cleanupResult.Failed) {
                $logTextBox.AppendText("Fehler beim Entfernen: $item`r`n")
            }
        }
    }

    if ($script:updateCapacityDisplay) {
        &$script:updateCapacityDisplay
    }

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
            $script:ApplicationTitle,
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
    $unhandledRecord = $_
    $unhandledMessage = Get-FriendlyErrorMessage -ErrorObject $unhandledRecord -Fallback 'Es ist ein unerwarteter Fehler aufgetreten.'
    Write-LauncherLog -Message ("Unbehandelter Fehler: " + $unhandledMessage)

    $detailText = ($unhandledRecord | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($detailText)) {
        foreach ($line in $detailText -split "`r?`n") {
            Write-LauncherLog -Message ("Detail: " + $line)
        }
    }

    $attachments = @()
    if ($script:currentLogFile -and (Test-Path -LiteralPath $script:currentLogFile)) {
        $attachments += $script:currentLogFile
    }
    if (Test-Path -LiteralPath $script:LauncherLogPath) {
        $attachments += $script:LauncherLogPath
    }

    $reportDetails = if (-not [string]::IsNullOrWhiteSpace($detailText)) { $detailText } else { $unhandledMessage }
    Submit-ErrorReport -Context 'Unerwarteter Fehler' -Details $reportDetails -Attachments $attachments

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "Es ist ein unerwarteter Fehler aufgetreten: $unhandledMessage`nWeitere Details finden Sie in '$script:LauncherLogPath'.",
            $script:ApplicationTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Error "Unerwarteter Fehler: $($_.Exception.Message)"
        Start-Sleep -Seconds 8
    }
}
