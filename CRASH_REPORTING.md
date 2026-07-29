# Automatische Crashberichte über Apple Mail

Crashberichte sind standardmäßig aktiviert und lassen sich unter
**Einstellungen → Crashberichte** jederzeit deaktivieren. Die Zieladresse ist
als `FindoraCrashReportRecipient` fest im App-Build konfiguriert und wird in
der Oberfläche weder angezeigt noch bearbeitet. Sie verweist ausschließlich
auf das Findora-Supportpostfach.

Findora legt beim Start einen lokalen Sitzungsmarker an und entfernt ihn beim
regulären Beenden. Bleibt er bestehen, erzeugt der nächste Start genau einen
ausstehenden Bericht. Ein passender macOS-Bericht aus
`~/Library/Logs/DiagnosticReports` wird auf 200 KB begrenzt und gemeinsam mit
höchstens 200 technischen Findora-Logzeilen bereinigt. Zusätzlich werden App-
und Build-Version, Start- und Laufzeit, macOS-Version, Architektur, Zahl der
aktiven CPU-Kerne und physischer Arbeitsspeicher aufgenommen.

Entfernt werden insbesondere:

- vollständige Home-, Volume-, `/private`- und `/tmp`-Pfade,
- `path=`-Felder aus Findora-Logs,
- E-Mail-Adressen.

Dokumentinhalte, Suchanfragen, Antworten, OCR-Texte und Dateinamen werden
nicht aufgenommen. Der lokale Bericht besitzt Dateirechte `0600`. Bei
aktivierter Funktion und gültiger Supportadresse sendet Apple Mail den Bericht
beim nächsten Start automatisch als Anhang. Beim ersten Versand kann macOS die
Automation von Apple Mail bestätigen lassen. Bei Fehlern bleibt der Bericht
für einen späteren Versuch erhalten.
