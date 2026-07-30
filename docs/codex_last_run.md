# Codex-Arbeitsstand

Stand: 30. Juli 2026

## Ausgangszustand

- Branch `main`, Arbeitsbaum vor Beginn sauber.
- Lokaler Ausgangscommit
  `6f5b3b2 docs: Master-Spezifikation verankern`; `main` lag dadurch einen
  Commit vor `origin/main`.
- `git pull --ff-only`: bereits aktuell.
- Baseline: 112 Tests bestanden, SQLite-Schema 15.
- Die Modell-, Wissens- und Graphstrukturen waren vorhanden, aber
  `KnowledgeExtractionCoordinator`, `ModelRouter` und die Wissensjobs waren
  noch nicht produktiv durch einen dauerhaften Worker verdrahtet.

## Umsetzung

### Agenten und End-to-End-Verarbeitung

- `KnowledgeAgentSystem` beansprucht die elf abhängigen Wissensjobs dauerhaft,
  wartet ohne Fehlerloop auf fehlende Modelle und setzt nach Aktivierung fort.
- Planner, Extraktion, Qualität, Projekt, Kommunikation, Erfahrung und Wartung
  arbeiten über typisierte Datenbankservices. Bestehende Import-, OCR-,
  Vision- und Antwortdienste melden Zustand und technische Läufe an denselben
  Agentenmonitor.
- `agent_runs` und `audit_log` speichern Rollen, Zustände, technische Zähler
  und Revisionen ohne Dokumenttext, Prompt oder Modelloutput.
- Deterministische Folgestufen validieren materialisierte Claims, bilden nur
  aus mehreren starken Signalen Projekte, erkennen Konflikte, erzeugen
  beleggebundene Kommunikationsereignisse und Zusammenfassungen und bauen ab
  drei aktiven Claims vorgeschlagenes Erfahrungswissen auf.

### Modelle und 8-GB-Grenze

- Die standardmäßig ausgeschaltete Opt-in-Einstellung für empfohlene Downloads
  lädt nun über den Capability-Router tatsächlich Qwen 3.5 und danach Phi-4
  Mini aus dem gepinnten Katalog.
- Gemma Vision bleibt experimentell und wird niemals durch dieses Opt-in
  stillschweigend geladen.
- `LocalGenerativeTaskGate` serialisiert Qwen, Phi, Antwortplanung,
  Antwortgenerierung und optische Analyse prozessweit. Jede große Laufzeit wird
  noch innerhalb dieser exklusiven Phase entladen; Qwen wird vor Phi
  freigegeben. Kritischer Speicherdruck pausiert neue Agentenarbeit.

### Wissen, Ontologie, Antworten und lokale API

- SQLite-Schema 16 ergänzt transaktional und mit vorgelagerter lokaler
  Sicherheitskopie erweiterbare Ontologietypen, Agentenläufe und Audit-Log.
- Neue Fachtypen werden lokal registriert und benötigen keine weitere
  Datenbankschemamigration. Nicht registrierte Modelltypen werden abgelehnt.
- Projektbeziehungen übernehmen ausschließlich die von starken Signalen
  referenzierten validierten Belege.
- Antworten zeigen die Klassen `Gesichert`, `Berechnet`, `Wahrscheinlichkeit`,
  `Erfahrung`, `Konflikt` oder `Unbekannt`; ohne reale Quelle und gültige
  Quellen-ID wird fail-closed `Unbekannt` verwendet.
- `LocalKnowledgeAPI` stellt eine transportneutrale lokale Fassade für Status,
  Reviews, begrenzte Graphabfragen, Ontologie und idempotente Neuanalyse bereit,
  öffnet aber keinen Netzwerklistener.

## Tests

Der Bestand wurde von 112 auf 117 Tests erweitert. Neue Abdeckung umfasst:

- vollständige produktive Wissensjobkette und Agenten-Audit;
- `waiting_for_model`, Wiederaufnahme und bestehende Service-Agenten;
- exklusive große Laufzeiten einschließlich Cleanup;
- erweiterbare lokale Ontologie ohne neue Migration;
- lokale API und fail-closed Antwortklassen.

## Noch extern abzunehmen

- Reale Mehr-GB-Gewichte wurden nicht heruntergeladen.
- Qwen 3.5, Phi-4 Mini und Gemma benötigen reale Laufzeit- und
  Qualitätsabnahmen mit installierten Gewichten.
- Verbindliche Modell-RAM-, Ladewechsel-, Langzeit- und End-to-End-Messungen
  benötigen die freigegebenen Gewichte auf dem 8-GB-Apple-Silicon-Prüfgerät.
- Gemma bleibt bis zur Lizenz- und Geräteabnahme experimentell.
- Die native Oberfläche benötigt weiterhin die dokumentierte visuelle
  Deutsch-/Englisch-, Hell-/Dunkel- und VoiceOver-Abnahme.
- Der eingebettete Modellkatalog wird vom App-Bundle umfasst, aktuell aber nur
  ad-hoc signiert. Eine vertrauenswürdige Developer-ID-Kette und eigene
  Publisher-Signaturen der Upstream-Gewichte sind noch nicht abgenommen;
  Gewichte werden bis dahin fail-closed über Revision, Größe und SHA-256
  geprüft.

## Schutzbestätigung

- keine Originaldokumente verändert, verschoben oder gelöscht;
- keine produktiven App-Daten migriert, repariert oder gelöscht;
- keine Modelle heruntergeladen oder in Git aufgenommen;
- keine Versionsänderung, kein Tag, kein Release und keine Notarisierung.

Beim ersten Smoke-Abgleich wählte die PID-Suche irrtümlich eine bereits seit
Stunden laufende Benutzerinstanz. Diese wurde ausschließlich read-only mit
`ps`/`lsof` betrachtet und weder beendet noch bedient. Der von Codex gestartete
Testprozess wurde sofort beendet. Die Wiederholung mit direkt ausgegebener PID
bestätigte vor jeder UI-Aktion ausschließlich den isolierten Testpfad.

## Abschlussprüfungen

- `swift test`: 117 Tests bestanden, 0 Fehler.
- `swift build -Xswiftc -strict-concurrency=complete
  -Xswiftc -warnings-as-errors`: bestanden.
- `./scripts/check-product-name.sh`: bestanden.
- `./scripts/check-localization.sh`: bestanden.
- `./scripts/build-app.sh release`: bestanden.
- `codesign --verify --deep --strict build/Findora.app`: bestanden
  (Ad-hoc-Signatur, Bundle-ID `de.findora.app`, arm64).
- `git diff --check`: bestanden.
- Isolierter Smoke-Test mit `FINDORA_TEST_ROOT` unter dem echten
  macOS-Temporärverzeichnis: bestanden. `lsof` zeigte für PID 44458 nur die
  isolierte Datenbank und keinen produktiven oder benutzerdefinierten Findora-
  Daten-, Dokument- oder Modellpfad.
- Isolierter Leerlauf-RSS: 107.680 KB.
- SQLite im isolierten Testbestand:
  `quick_check = ok`, `integrity_check = ok`, 0
  Fremdschlüsselverletzungen, Schema 16 und 25 aktive Ontologietypen.

Commit und Push nach `origin/main` werden im Abschlussbericht mit Hash und
Ziel dokumentiert.
