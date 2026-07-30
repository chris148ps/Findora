# Findora Master-Spezifikation

## Lokale KI-Wissensplattform

**Version 1.0 (Living Specification)**

**Stand: 30.07.2026**

> Dieses Dokument ist die langfristige technische Zielarchitektur für
> Findora. Es dient als verbindliche Referenz für alle zukünftigen
> Entwicklungsaufträge.

## 1. Vision

Findora ist keine Dokumentensuche.

Findora ist eine vollständig lokale KI-Wissensplattform, die aus
Dokumenten, E-Mails, Bildern und weiteren Datenquellen nachvollziehbares
Wissen aufbaut.

Grundprinzipien:

- vollständig lokal
- Datenschutz by Design
- Explainable AI
- Quellenpflicht
- keine Halluzinationen
- modulare Architektur
- selbstverbessernd
- revisionssicher
- Apple-Silicon-optimiert
- langfristig erweiterbar

## 2. Gesamtarchitektur

Schichten:

1. Import Layer
2. OCR/Vision Layer
3. Dokumentklassifikation
4. Entitäts- und Faktenextraktion
5. Wissensgraph
6. Kommunikationsgraph
7. Projektgraph
8. Ereignisgraph
9. Zeitgraph
10. Erfahrungsgraph
11. Antwort-Engine
12. Agenten-Engine
13. Hintergrundjobs
14. UI
15. APIs

## 3. KI-Modelle

- Primär: Qwen 3.5 4B
- Prüfung: Phi-4 Mini
- Vision: Gemma 4 E2B

Alle Modelle werden über einen gemeinsamen `ModelManager` verwaltet.

`ModelManager`:

- Download
- SHA-256
- Versionierung
- RAM-Budget
- Laden
- Entladen
- Routing
- Leases
- Prioritäten
- Diagnosen

## 4. Wissensmodell

Persistente Objekte:

- Dokument
- Seite
- Abschnitt
- Entität
- Fakt
- Beziehung
- Quelle
- Projekt
- Kommunikation
- Ereignis
- Aufgabe
- Termin
- Wissenslücke
- Zusammenfassung
- Erfahrungswissen
- Statistik
- Trend

Jedes Objekt besitzt UUID, Revision, Zeitstempel und Herkunft.

## 5. Kommunikationssystem

Unterstützung für:

- EML
- MBOX
- MSG (zukünftig)

Automatische Erkennung:

- Threads
- Antworten
- Teilnehmer
- Anhänge
- Entscheidungen
- Zusagen
- Rückfragen
- Termine
- Aufgaben
- Verantwortlichkeiten

## 6. Projektbildung

Mehrstufige Bewertung:

- Regeln
- Identifikatoren
- Entitäten
- Zeit
- Kommunikation
- Embeddings
- Qwen
- Phi-Prüfung

Unsichere Ergebnisse bleiben Vorschläge.

## 7. Wissensgraph

Grapharten:

- Wissensgraph
- Kommunikationsgraph
- Projektgraph
- Ereignisgraph
- Zeitgraph
- Erfahrungsgraph

Alle Graphen sind miteinander verknüpft.

## 8. Agentensystem

Agenten:

- Planner
- Dokument
- OCR
- Vision
- Extraktion
- Validierung
- Kommunikation
- Projekt
- Antwort
- Erfahrung
- Qualität
- Wartung

Agenten kommunizieren ausschließlich über gemeinsame Services und den
Wissensgraphen.

## 9. Antwortsystem

Pipeline:

```text
Frage → Intent → Plan → Wissensgraph → Kommunikation → Projekte → FTS →
Vektorsuche → Quellen → Antwort → Validierung
```

Antworten unterscheiden:

- gesichert
- berechnet
- Erfahrungswissen
- Wahrscheinlichkeit
- Konflikt
- unbekannt

## 10. Langzeitgedächtnis

Findora erkennt:

- Muster
- Trends
- Fehler
- Lösungen
- typische Abläufe
- ähnliche Projekte
- fehlende Dokumente

Erfahrungswissen darf niemals Fakten ersetzen.

## 11. Ontologie

Standardisierte Typen für:

- Personen
- Firmen
- Geräte
- Dokumente
- Verträge
- Behörden
- PV
- Speicher
- Wallbox
- Wechselrichter
- Energie
- Recht
- Finanzen
- Medizin (zukünftig)

Neue Typen müssen ohne Datenmigration ergänzt werden können.

## 12. Qualitätsmodell

Jeder Fakt benötigt:

- Quelle
- Dokument
- Seite
- Textstelle
- Confidence
- Modell
- Revision
- Status

Mehrmodellprüfung bei Unsicherheit.

## 13. Hintergrunddienste

- inkrementelle Analyse
- Konsolidierung
- Qualitätsprüfung
- Mustererkennung
- Graphoptimierung
- Zusammenfassungen
- Wissenslücken
- Modellwartung

## 14. Entwicklerbereich

Anzeigen:

- Graphen
- Agenten
- Modelle
- Jobs
- Konflikte
- Revisionen
- Performance
- Speicher

Interaktive Werkzeuge:

- bestätigen
- trennen
- zusammenführen
- neu analysieren
- Rollback

## 15. API-Architektur

Vorbereitung für:

- lokale Plugins
- MCP
- REST
- Shortcuts
- Apple Intelligence
- externe lokale Dienste

Keine Cloud-Pflicht.

## 16. Performance

Optimiert für 8 GB:

- nur ein großes Modell gleichzeitig
- dynamische Kontextgrößen
- adaptive Batchgrößen
- Prioritäten
- Leerlaufentladung

## 17. Sicherheit

- vollständige Lokalverarbeitung
- keine Dokumentübertragung
- signierte Modellkataloge
- Prüfsummen
- transaktionale Migrationen
- Audit-Log
- Revisionshistorie

## 18. Roadmap

1. Phase 1 – vollständige Pipeline
2. Phase 2 – Agentensystem
3. Phase 3 – Langzeitgedächtnis
4. Phase 4 – Ontologie
5. Phase 5 – Plugin-System
6. Phase 6 – Proaktive Assistenz
7. Phase 7 – Wissensplattform

## 19. Nichtziele

- keine Cloud-Abhängigkeit
- keine automatischen unbelegten Fakten
- keine Änderung von Originaldokumenten
- keine intransparente KI

## 20. Leitprinzip

Findora soll jederzeit erklären können:

- Woher stammt dieses Wissen?
- Warum wurde diese Beziehung erzeugt?
- Welche Dokumente belegen sie?
- Welche Modelle waren beteiligt?
- Wie sicher ist die Aussage?
- Wann wurde sie zuletzt überprüft?

Kann eine dieser Fragen nicht beantwortet werden, gilt die Information
nicht als gesichertes Wissen.
