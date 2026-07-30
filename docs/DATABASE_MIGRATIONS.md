# Versionierte und inkrementelle Datenbankmigrationen

## Schema-Version

Findora erwartet Schema-Version 15. Beim Start werden aktuelle und erwartete
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

## Migration 15: lokale Wissensschicht

Migration 15 ergänzt additiv Entitäten, Aliase, Kennungen, Claims, Fakten,
Relationen, Belege, Konflikte, Revisionen, reversible Merge- und
Negativregeln, Projekte, Zusammenfassungsabhängigkeiten, Wissensjobs,
Wissenslücken, Kommunikation sowie Muster, Statistiken, Trends und
Empfehlungen.

Vor einem Upgrade einer bestehenden Datenbank wird nach einem vollständigen
WAL-Checkpoint eine lokale SQLite-Kopie mit dem Suffix
`pre-knowledge-v<alt>-<Zeitstempel>.sqlite3` neben der aktiven Datenbank
angelegt. Sie liegt im Findora-Datenspeicher und wird nicht in Git aufgenommen.

Alle Tabellen und Indizes werden wiederaufnahmesicher angelegt. Der
Migrationsmarker wird erst nach erfolgreicher Transaktion geschrieben.
Wissensbelege verwenden für entfernte Dokument-, Seiten- und Chunkreferenzen
`SET NULL`, damit die historische Aussage zunächst als fehlender Beleg
prüfbar bleibt.

Der isolierte Wissensreset leert ausschließlich Wissens-, Kommunikations- und
Erfahrungstabellen. Dokumente, Seiten, OCR, Chunks, FTS und Embeddings sind
nicht Teil dieses Resets.

Migrationstests decken direkte Upgrades von Schema 10 und 11, Schema 15,
Rollback und
Fortsetzung nach einem künstlichen Abbruch, Daten- und Embedding-Erhalt sowie
`quick_check` und `integrity_check` ab.
