# Versionierte und inkrementelle Datenbankmigrationen

## Schema-Version

Findora erwartet Schema-Version 14. Beim Start werden aktuelle und erwartete
Version verglichen und ausschließlich fehlende Migrationen in aufsteigender
Reihenfolge ausgeführt. Jede Migration läuft in einer SQLite-Transaktion und
wird erst danach in `schema_migrations` dokumentiert.

Ein Abbruch hinterlässt weder eine teilweise neue Version noch gelöschte
Bestandsdaten. Der nächste Start kann dieselbe Migration erneut ausführen.

## Dokumentbezogene Versionen

`document_analysis_versions` führt je Dokument unabhängige Versionen für:

- OCR
- Parser
- Textabschnitte
- Embeddings
- lokale KI-Analyse
- Personenanalyse
- Projektanalyse
- Zusammenfassung

Eine neue Analyseversion macht nur das betroffene Feld veraltet. Sie erzwingt
keine OCR, keine neue Textextraktion und keine Neuerzeugung anderer Analysen.

## Hintergrund-Upgrades

`analysis_upgrade_jobs` kann fehlende oder veraltete Analysen
transaktional speichern. Für die zurückgestellten Partner- und
Projektfunktionen wird derzeit kein Hintergrundlauf in der Oberfläche
angeboten.

OCR und Embeddings werden bewusst nicht automatisch erneuert. Die Ansicht
**Versionen** zeigt fehlende und veraltete Daten und bietet dafür getrennte,
ausdrücklich zu startende Wartungsaktionen.

## Kompatibilitätsgarantie

Migrationen 11 bis 14 ergänzen Tabellen, Indizes, Beziehungen und Metadaten.
Sie löschen oder ersetzen keine vorhandenen Dokumente, OCR-Texte, Maildaten,
Chunks oder Embeddings. Eine vollständige Neuindexierung bleibt eine
bestätigte Nutzeraktion.

Migration 13 ergänzt nur Quelldatei-Metadaten und persistente Unterdrückungen
für einzeln entfernte Mail-Dubletten. Die Spaltenerweiterung ist
wiederaufnahmesicher, falls eine Test- oder Reparatursituation die
Migrationsmarke zurücksetzt.

Migration 14 ergänzt pro Seite die ausgewählte Textquelle, getrennte native,
OCR- und optische Textvorschläge, Qualitäts-/Engine-/Analysemetadaten,
Apple-Vision-Bounding-Boxes und lokale optische Analyseergebnisse. Außerdem
werden Reparaturstatus und konkrete Dateibearbeitungsfehler gespeichert. Alle
Spalten und Tabellen werden vor dem Anlegen geprüft, sodass die Migration
wiederholbar bleibt. Bestehende manuelle Texte werden als `manual` erhalten;
es gibt keinen Datenbankreset.

Migrationstests decken direkte Upgrades von Schema 10 und 11, Rollback und
Fortsetzung nach einem künstlichen Abbruch, Daten- und Embedding-Erhalt sowie
`quick_check` und `integrity_check` ab.
