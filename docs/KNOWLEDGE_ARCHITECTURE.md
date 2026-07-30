# Wissensarchitektur

Stand: 30. Juli 2026

## Ziel und Grenzen

Die Wissensschicht ist ein lokaler, abgeleiteter und revisionsfähiger Aufbau
über dem unveränderten Dokumentindex. Sie darf Originaldateien, OCR-Text und
klassische Suche weder ersetzen noch verändern.

```text
Originaldatei → Dokument (SHA-256) → Seite und Textquelle
→ Chunk / FTS / Embedding → Entität → belegter Claim
→ Fakt oder Relation → Projekt / Kommunikation
→ Zusammenfassung / Konflikt / Wissenslücke
→ Statistik / Erfahrungswissen
```

## Komponenten

- `KnowledgeExtractionCoordinator` erzeugt begrenzte Seitenprompts und besitzt
  als einzige Modellkomponente den geprüften Speicherpfad.
- `KnowledgeExtractionValidator` prüft Schema, IDs, Seite, Chunk,
  Zeichenbereich, wörtlichen Beleg, Bounding Box, Datentyp und Confidence.
- `SQLiteDatabase` speichert eine validierte Extraktion vollständig oder gar
  nicht und führt Revisions-, Invalidierungs-, Graph- und Resetoperationen aus.
- `ModelRouter`, `ModelMemoryBudget` und `ModelLeaseManager` wählen,
  reservieren, laden und entladen capability-basiert.
- `HybridSearchService` führt Wissensbelege mit FTS, Dateinamen und optionaler
  Vektorsuche zusammen. Antworten erhalten weiterhin Originalquellen.

## Idempotente Aktualisierung

Beim Indexieren wird aus Dokumenthash, Analyseversion und sortiertem Chunktext
ein Inputhash gebildet. Die Job-Eindeutigkeit ist
`job_kind + target_key + input_hash`; doppelte Starts legen keine doppelten
Jobs an.

Bei Änderungen werden alte Belege `stale`, abhängige Aussagen ohne
Alternativquelle zurückgezogen und Zusammenfassungen invalidiert. Bei einer
entfernten Datei werden Belege `missing`. Erst wenn kein weiterer gültiger
Beleg denselben Claim trägt, wird er `deprecated` beziehungsweise bei
Nutzerbestätigung `review_required`.

## Entitäten, Projekte und Kommunikation

Die erste Entitätsstufe ist deterministisch: Normalisierung, Alias, eindeutige
Kennung, Adresse und Kontext. Eine Negativregel hat immer Vorrang.
Automatisches Zusammenführen verlangt mindestens 0,90 Confidence und starke
Signale.

Projektkandidaten kombinieren Kennungen, Adressen, Entitäten, Zeit und
Semantik. Ein häufiger Personenname allein reicht nie.

E-Mails werden anhand von `conversation_id`, `Message-ID` /
`In-Reply-To` und ersatzweise der Kombination aus normalisiertem Betreff und
Teilnehmern in Threads eingeordnet. Anhänge behalten gleichzeitig ihre
E-Mail-, Dokument- und SHA-256-Identität. Strukturierte Ereignisse benötigen
denselben Claim- und Belegpfad wie PDF-Fakten.

## Erfahrungswissen

Schema 15 stellt Muster, Statistik, Trend, Musterbeleg und Empfehlung getrennt
bereit. Nur aktive `verified`- oder `supported`-Claims dürfen Statistiken
stützen. Erfahrungswissen wird immer als Muster oder Statistik und nie als
Einzelfakt bezeichnet.

## Reset und Deaktivierung

`knowledgeEnabled = 0` verhindert neue automatische Wissensjobs und pausiert
wartende Jobs. `RESET KNOWLEDGE` leert nur die Wissens-, Kommunikations- und
Erfahrungstabellen. Der klassische Suchindex bleibt verwendbar.

## Technische Abnahmegrenze

Schema, Katalog, Orchestrierung, geprüfter Speicherpfad, Jobplanung,
Graphabfrage, Kommunikationsstruktur, Diagnosesichten und
Graph-/FTS-/Vektor-Retrieval sind implementiert. Reale End-to-End-Läufe mit
allen drei Mehr-GB-Modellen sowie belastbare 8-GB-Messreihen benötigen die
lokal installierten Gewichte und Zielhardware; Unit-Tests laden diese bewusst
nicht.
