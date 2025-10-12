# Winback

Dieses Repository enthält ein PowerShell-Skript mit grafischer Oberfläche, das ein bestimmtes Verzeichnis auf zwei USB-Festplatten sichert. An geraden Kalendertagen wird auf die erste Festplatte kopiert, an ungeraden Tagen auf die zweite. Nach erfolgreichem Backup kann der PC automatisch heruntergefahren werden.

## Installation

1. Laden Sie den Ordner `scripts` auf Ihren Windows-11-PC.
2. Öffnen Sie `scripts/odd-even-backup.ps1` in einem Texteditor (z. B. Notepad) und passen Sie folgende Werte an:
   - `SourcePath`: Pfad des Ordners, der gesichert werden soll.
   - `EvenDayTargetConfig` und `OddDayTargetConfig`: Hier beschreiben Sie die beiden USB-Festplatten.
     - Geben Sie idealerweise `VolumeLabel` (z. B. `Festplatte A`) sowie `RelativePath` (z. B. `Backups`) an. Damit findet das Skript die Festplatte anhand ihres Namens, egal welchen Laufwerksbuchstaben Windows vergibt.
     - Alternativ können Sie ein festes `Path` setzen (z. B. `E:\Backups`). Optional lässt sich `DriveLetter` ergänzen, um Name und Buchstaben gemeinsam anzuzeigen.
   - `UseTimestampFolder` (optional): Auf `true` setzen, wenn für jedes Backup ein Unterordner erstellt werden soll.
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

1. Verbinden Sie beide USB-Festplatten mit dem PC.
2. Klicken Sie mit der rechten Maustaste auf die Datei `odd-even-backup.ps1` und wählen Sie **Mit PowerShell ausführen**. Das Skript startet automatisch im benötigten STA-Modus.
3. Die Oberfläche zeigt Quelle, tagesabhängiges Ziel und einen farblich hervorgehobenen Statusbereich an. Starten Sie die Sicherung über **Backup starten** – während des Kopiervorgangs läuft ein dezenter Fortschrittsbalken, und im Protokollauszug erscheinen der Logpfad sowie die letzten Zeilen der Robocopy-Datei.
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
- Die Robocopy-Protokolle sowie das Startprotokoll `launcher.log` finden Sie im Ordner, den Sie über `LogDirectory` festgelegt haben. Das Startprotokoll hält jetzt auch fest, ob eine Sicherung erfolgreich beendet oder mit einem Fehler abgebrochen wurde.
- Wenn sich die PowerShell direkt wieder schließt, öffnen Sie `launcher.log`, um die Ursache zu sehen (z. B. fehlende USB-Festplatte oder blockierte Datei). Bei blockierten Dateien hilft `Unblock-File -Path .\odd-even-backup.ps1` in einer administrativen PowerShell.
- Der Statusbereich und zusätzliche Hinweisdialoge geben klare Fehlermeldungen aus, z. B. wenn ein Laufwerk nicht gefunden wird oder Robocopy mit einem Fehlercode stoppt.
- Prüfen Sie regelmäßig die Log-Dateien, um sicherzustellen, dass die Sicherung erfolgreich war.
