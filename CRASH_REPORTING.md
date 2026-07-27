# Automatische Crashberichte über Apple Mail

Crashberichte sind standardmäßig deaktiviert. Unter
**Einstellungen → Crashberichte** lassen sie sich ausdrücklich aktivieren.
Die Empfängeradresse ist in der internen Version änderbar. Für eine spätere
Verkaufsversion kann dieses Eingabefeld entfernt und durch eine fest
konfigurierte Supportadresse ersetzt werden, ohne die Erkennungs- oder
Bereinigungslogik zu ändern.

Findora legt beim Start einen lokalen Sitzungsmarker an und entfernt ihn beim
regulären Beenden. Bleibt er bestehen, erzeugt der nächste Start genau einen
ausstehenden Bericht. Ein passender macOS-Bericht aus
`~/Library/Logs/DiagnosticReports` wird auf 200 KB begrenzt und gemeinsam mit
höchstens 200 technischen Findora-Logzeilen bereinigt.

Entfernt werden insbesondere:

- vollständige Home-, Volume-, `/private`- und `/tmp`-Pfade,
- `path=`-Felder aus Findora-Logs,
- E-Mail-Adressen.

Dokumentinhalte, Suchanfragen und Antworten werden nicht aufgenommen. Der
lokale Bericht besitzt Dateirechte `0600`. Bei aktivierter Funktion und
gültiger Empfängeradresse sendet Apple Mail den Bericht beim nächsten Start
automatisch als Anhang. Beim ersten Versand kann macOS die Automation von
Apple Mail bestätigen lassen. Bei Fehlern bleibt der Bericht für einen
späteren Versuch erhalten.
