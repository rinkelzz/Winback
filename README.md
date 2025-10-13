# Backup by RinkelTech

Dieses Repository enthält ein PowerShell-Skript mit grafischer Oberfläche, das ein bestimmtes Verzeichnis auf zwei USB-Festplatten sichert. An geraden Kalendertagen wird auf die erste Festplatte kopiert, an ungeraden Tagen auf die zweite. Nach erfolgreichem Backup kann der PC automatisch heruntergefahren werden.

## Installation

1. Laden Sie den Ordner `scripts` auf Ihren Windows-11-PC.
2. Öffnen Sie `scripts/odd-even-backup.ps1` in einem Texteditor (z. B. Notepad) und passen Sie folgende Werte an:
   - `SourcePath`: Pfad des Ordners, der gesichert werden soll.
   - `EvenDayTargetConfig` und `OddDayTargetConfig`: Hier beschreiben Sie die beiden USB-Festplatten.
     - Geben Sie idealerweise `VolumeLabel` (z. B. `Festplatte A`) sowie `RelativePath` (z. B. `Backups`) an. Damit findet das Skript die Festplatte anhand ihres Namens, egal welchen Laufwerksbuchstaben Windows vergibt.
     - Alternativ können Sie ein festes `Path` setzen (z. B. `E:\Backups`). Optional lässt sich `DriveLetter` ergänzen, um Name und Buchstaben gemeinsam anzuzeigen.
   - `LicenseCompanyName` (optional): Text, der nach „license for“ im Fenstertitel erscheint – z. B. der Name Ihres Unternehmens.
   - `UseTimestampFolder` (optional): Auf `true` setzen, wenn für jedes Backup ein Unterordner erstellt werden soll.
   - `TimestampFolderFormat` (optional): Datumsformat für diese Unterordner (Standard `yyyy_MM_dd-HH:mm`). Ungültige Zeichen für Windows-Pfade (z. B. `:`) werden automatisch durch Unterstriche ersetzt.
   - `TimestampRetentionDays` (optional): Anzahl der Tage, nach denen alte Zeitstempel-Ordner automatisch gelöscht werden. `0` (Standard) deaktiviert die Bereinigung.
   - `LogDirectory` (optional): Speicherort für die Robocopy-Protokolle. Standardmäßig werden die Dateien im Dokumente-Ordner unter `WinbackLogs` abgelegt, wo auch das Startprotokoll `launcher.log` gespeichert wird.

> **Hinweis:** Durch die Zuordnung über `VolumeLabel` spielt es keine Rolle mehr, welchen Laufwerksbuchstaben Windows den Festplatten zuweist.

Ein typischer Konfigurationsblock sieht z. B. so aus:

```powershell
$EvenDayTargetConfig = @{
    VolumeLabel  = 'Festplatte A'
    RelativePath = 'Backups'
}

$OddDayTargetConfig = @{
    VolumeLabel  = 'Festplatte B'
    RelativePath = 'Backups'
}
```

## Verwendung

1. Verbinden Sie mindestens die USB-Festplatte, die dem aktuellen Kalendertag zugeordnet ist. Ist nur eine der beiden angeschlossen, startet die Sicherung trotzdem – das Skript überprüft anhand des eingestellten Datenträgers (Volume-Label/Laufwerksbuchstabe), ob wirklich das richtige Ziel gefunden wurde.
2. Klicken Sie mit der rechten Maustaste auf die Datei `odd-even-backup.ps1` und wählen Sie **Mit PowerShell ausführen**. Das Skript startet automatisch im benötigten STA-Modus.
3. Die Oberfläche zeigt Quelle, tagesabhängiges Ziel und einen farblich hervorgehobenen Statusbereich an. Der Fenstertitel lautet „Backup by RinkelTech license for …“ und ergänzt – sofern konfiguriert – automatisch Ihren Firmennamen. Starten Sie die Sicherung über **Backup starten** – während des Kopiervorgangs läuft ein dezenter Fortschrittsbalken, und im Protokollauszug erscheinen der Logpfad sowie die letzten Zeilen der Robocopy-Datei.
4. Aktivieren Sie optional die Checkbox **Nach erfolgreichem Backup herunterfahren**, um den PC direkt nach erfolgreichem Kopiervorgang herunterzufahren.
5. Über **Logdatei öffnen** lässt sich der vollständige Robocopy-Log anschließend in Notepad ansehen.

### Desktop-Verknüpfung „Herunterfahren“

Damit Sie das Backup und den anschließenden Shutdown per Doppelklick starten können:

1. Klicken Sie mit der rechten Maustaste auf eine freie Stelle auf dem Desktop und wählen Sie **Neu → Verknüpfung**.
2. Geben Sie als Speicherort folgenden Befehl ein (Pfad anpassen):
   ```
   powershell.exe -ExecutionPolicy Bypass -File "C:\\Pfad\\zu\\odd-even-backup.ps1"
   ```
3. Vergeben Sie einen Namen, z. B. `Backup & Herunterfahren`.
4. Optional können Sie über **Eigenschaften → Anderes Symbol** ein passendes Icon wählen.

Die Verknüpfung startet die Oberfläche, über die Sie das Backup auslösen und – falls gewünscht – das automatische Herunterfahren aktivieren können.

## Weitere Hinweise

- Das Skript verwendet `robocopy`, das standardmäßig unter Windows 11 vorhanden ist.
- Die Robocopy-Protokolle sowie das Startprotokoll `launcher.log` finden Sie im Ordner, den Sie über `LogDirectory` festgelegt haben. Das Startprotokoll dokumentiert Startzeit, Abschluss (inklusive Robocopy-Code) und mögliche Fehler.
- Wenn sich die PowerShell direkt wieder schließt, öffnen Sie `launcher.log`, um die Ursache zu sehen (z. B. fehlende USB-Festplatte oder blockierte Datei). Bei blockierten Dateien hilft `Unblock-File -Path .\odd-even-backup.ps1` in einer administrativen PowerShell.
- Der Statusbereich und zusätzliche Hinweisdialoge geben klare Fehlermeldungen aus, z. B. wenn ein Laufwerk nicht gefunden wird oder Robocopy mit einem Fehlercode stoppt.
- Während des Kopiervorgangs bleibt die Oberfläche aktiv und verhindert ein versehentliches Schließen. Nach Abschluss wird der Startknopf wieder freigegeben und Sie können die Logdatei direkt öffnen.
- Prüfen Sie regelmäßig die Log-Dateien, um sicherzustellen, dass die Sicherung erfolgreich war.
- Bei aktivem Zeitstempelmodus zeigt der Protokollauszug zusätzlich den angeforderten Ordnernamen an; der tatsächlich angelegte Ordner nutzt eine bereinigte Variante ohne Windows-Sonderzeichen.
- Ist `TimestampRetentionDays` größer als `0`, entfernt das Skript nach einem erfolgreichen Lauf automatisch alle älteren Zeitstempel-Ordner aus dem Zielverzeichnis und protokolliert jeden gelöschten Ordner im Fenster sowie in `launcher.log`.
- Direkt nach einem erfolgreichen Kopiervorgang aktualisiert das Skript die Zeitstempel des frisch erstellten Backup-Ordners und schützt ihn zusätzlich explizit vor der Bereinigung, damit neue Sicherungen auch bei sehr kurzen Aufbewahrungsfristen erhalten bleiben.
