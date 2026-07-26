# Versionierte und inkrementelle Datenbankmigrationen

## Schema-Version

Findora erwartet Schema-Version 12. Beim Start werden aktuelle und erwartete
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

`analysis_upgrade_jobs` enthält ausschließlich fehlende oder veraltete
Analysen. Der aktuelle Hintergrundlauf ergänzt Personen- und Projektanalysen
in kleinen, transaktionalen Batches. Er kann pausiert und später fortgesetzt
werden.

OCR und Embeddings werden bewusst nicht automatisch erneuert. Die Ansicht
**Versionen** zeigt fehlende und veraltete Daten und bietet dafür getrennte,
ausdrücklich zu startende Wartungsaktionen.

## Kompatibilitätsgarantie

Migrationen 11 und 12 ergänzen Tabellen, Indizes, Beziehungen und Metadaten.
Sie löschen oder ersetzen keine vorhandenen Dokumente, OCR-Texte, Maildaten,
Chunks oder Embeddings. Eine vollständige Neuindexierung bleibt eine
bestätigte Nutzeraktion.

Migrationstests decken direkte Upgrades von Schema 10 und 11, Rollback und
Fortsetzung nach einem künstlichen Abbruch, Daten- und Embedding-Erhalt sowie
`quick_check` und `integrity_check` ab.
