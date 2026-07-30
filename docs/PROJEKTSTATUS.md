# Projektstatus

Stand: 30. Juli 2026

## Implementiert

- Modellkatalog Schema 2 mit Qwen 3.5 4B, Phi-4 Mini und experimentellem
  Gemma 4 E2B sowie unveränderten älteren Modellen.
- Capability-Routing, RAM-Budget, priorisierte exklusive Leases, Timeout,
  Abbruch, Cooldown und Speicherdrucksperre.
- SQLite-Schema 16 mit Sicherheitskopie vor Bestandsmigration,
  Wissens-/Kommunikations-/Erfahrungstabellen und revisionsfähigen Belegen.
- Strukturiertes JSON, fail-closed Quellenprüfung und transaktionaler
  Speicherpfad.
- Idempotente Jobs und sichere Invalidierung geänderter/entfernter Quellen.
- deterministische Entitäts- und Projekt-Signalstufen mit Negativregeln.
- begrenzte SQLite-Graphabfrage und Wissens-/FTS-/Vektor-Retrieval.
- Kommunikations-Threads und dauerhafte Anhangsverknüpfungen.
- Entwickleransichten für Übersicht, Projekte, Entitäten, Claims,
  Kommunikation, Erfahrungswissen und Wartung.
- persistenter nativer Antwort-/Quellen-Splitter mit Mindestgrößen,
  Doppelklick-Reset und kompakter Ersatzdarstellung.
- Wissensfunktion deaktivierbar; klassischer Index bleibt unabhängig.
- produktiver lokaler Agentenworker für die abhängige Wissensjobkette;
- exklusive Qwen-/Phi-/Vision-/Antwortausführung und reales
  capability-basiertes Opt-in-Downloadrouting;
- Agentenmonitor, technische Agentenläufe, Audit-Log und erweiterbare
  Ontologietypen;
- deterministische Konflikt-, Kommunikationsereignis-, Projekt-,
  Zusammenfassungs- und Erfahrungsfolgestufen;
- sichtbare Antwortklassen mit fail-closed `Unbekannt` ohne gültige Quellen.
- unsichere Modellableitungen werden nie als Fakten/Relationen gespeichert;
  offene Informationen werden als später auflösbare Wissenslücken geführt.

## Abnahmegrenzen

Unit-Tests verwenden synthetische Daten und laden keine Mehr-GB-Gewichte.
Reale Qwen-/Phi-/Gemma-Läufe und belastbare 8-GB-Performancewerte sind eine
getrennte Hardware-Abnahme. Gemma bleibt experimentell. Erfahrungsstatistiken
entstehen erst ab drei aktiven, belegten Claims und werden zunächst nur als
Vorschlag gespeichert; Testdaten werden nicht in produktive Bestände
übernommen.
