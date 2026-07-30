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
- `KnowledgeAgentSystem` beansprucht die persistente, abhängige Jobkette,
  führt die lokale Extraktion aus und delegiert Folgearbeiten ausschließlich
  über typisierte Services und validierten Datenbankzustand.
- `LocalGenerativeTaskGate` serialisiert Qwen-, Phi-, Antwort- und
  Vision-Aufgaben pro Prozess. Vor der unabhängigen Phi-Prüfung wird Qwen
  vollständig entladen.
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

Die produktive Erfahrungsstufe beginnt erst ab drei aktiven, belegten Claims
desselben Musters. Sie speichert Statistik und Muster zunächst als
`proposed`; sie bestätigt keine Erfahrung automatisch und ersetzt keinen
Einzelfakt.

## Agentensystem

Der Monitor kennt Planner-, Import-, OCR-, Vision-, Extraktions-,
Kommunikations-, Projekt-, Qualitäts-, Erfahrungs-, Antwort- und
Wartungs-Agent. Die bestehenden Import-, OCR-, Vision-, Antwort- und
Wartungsservices melden ihren Laufzustand an denselben Monitor. Die
Wissensagenten arbeiten die SQLite-Jobabhängigkeiten aus Schema 16 ab.

Der erste Modelllauf erzeugt ein vollständiges, schema- und
quellenvalidiertes Extraktionsobjekt. Nachfolgende Agenten prüfen und
materialisieren den gespeicherten Zustand; sie akzeptieren keinen freien
Modelltext. Technische Läufe und Zustandswechsel werden ohne Inhaltsdaten in
`agent_runs` und `audit_log` protokolliert.

## Ontologie

`KnowledgeEntityType` ist ein erweiterbarer, syntaktisch begrenzter Schlüssel.
Eingebaute Typen werden in `ontology_types` gespiegelt. Ein lokal definierter
Typ kann registriert werden, ohne das SQLite-Schema zu ändern; nicht
registrierte Modelltypen werden vor dem Speichern abgelehnt.

## Antwortklassen

Die Oberfläche kennzeichnet Ergebnisse als Gesichert, Berechnet,
Wahrscheinlichkeit, Erfahrung, Konflikt oder Unbekannt. Ohne gültige
Quellen-ID und Originalquelle lautet die Klasse immer `Unbekannt`.

## Reset und Deaktivierung

`knowledgeEnabled = 0` verhindert neue automatische Wissensjobs und pausiert
wartende Jobs. `RESET KNOWLEDGE` leert nur die Wissens-, Kommunikations- und
Erfahrungstabellen. Der klassische Suchindex bleibt verwendbar.

## Technische Abnahmegrenze

Schema, Katalog, produktiver Agentenworker, geprüfter Speicherpfad,
Jobplanung, Graphabfrage, Kommunikationsstruktur, Diagnosesichten und
Graph-/FTS-/Vektor-Retrieval sind implementiert. Reale End-to-End-Läufe mit
allen drei Mehr-GB-Modellen sowie belastbare 8-GB-Messreihen benötigen die
lokal installierten Gewichte und Zielhardware; Unit-Tests laden diese bewusst
nicht.
