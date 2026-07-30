# Entwicklerhandbuch

Stand: 30. Juli 2026

## Einstieg

Vor Änderungen gelten `AGENTS.md`, `docs/CODEX_WORKFLOW.md` und
`docs/FINDORA_MASTER_SPECIFICATION.md`. Der reale Stand steht in
`docs/PROJEKTSTATUS.md`; offene Hardwareabnahmen in `docs/NEXT_TASK.md`.

## Modulgrenzen

- `FindoraCore`: Datenmodelle, OCR-/Import-/Indexdienste, SQLite,
  Wissensvalidierung, Agentensystem und lokale API;
- `FindoraMLX`: lokale MLX-Embeddings, Text- und Visionlaufzeiten;
- `FindoraApp`: SwiftUI/AppKit, Berechtigungen und produktive Verdrahtung.

Modellimplementierungen liefern nur Bytes oder typisierte Antworten. Nur
`KnowledgeExtractionValidator` und `SQLiteDatabase.storeValidatedKnowledge`
dürfen Modelloutput in die Wissensschicht überführen.

## Wissenspipeline

`indexDocument` bildet einen Inputhash und reiht elf abhängige Jobs ein.
`KnowledgeAgentSystem` beansprucht sie. Der Planner startet eine vollständige
Qwen-Extraktion; eine optionale Phi-Prüfung sieht dieselben Originalbelege,
aber keine Begründung des Primärmodells. Folgeagenten lesen nur den
transaktional gespeicherten Zustand.

Neue Agentenstufen benötigen:

1. einen stabilen `KnowledgeJobKind`;
2. eine eindeutige idempotente Signatur;
3. eine Abhängigkeit in der Jobkette;
4. eine typisierte Serviceoperation;
5. Audit ohne Inhaltsdaten;
6. synthetische Erfolgs-, Fehler-, Wiederaufnahme- und Idempotenztests.

## Ontologie

Neue Fachtypen werden über `registerOntologyType` als Daten registriert. Der
Schlüssel muss `^[a-z][a-z0-9_]{1,63}$` erfüllen. Nicht registrierte Typen
werden beim Speichern abgelehnt. Eine SQLite-Migration ist nur für neue
Strukturen, nicht für neue Fachtypen erforderlich.

## Testen

```bash
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./scripts/check-product-name.sh
./scripts/check-localization.sh
./scripts/build-app.sh release
codesign --verify --deep --strict build/Findora.app
git diff --check
```

Reale Modelltests sind Opt-in und dürfen ausschließlich synthetische Quellen
verwenden. UI-Smokes benötigen `FINDORA_TEST_ROOT` unter dem echten macOS-
Temporärverzeichnis und die vorgeschriebene `lsof`-Prüfung.

## Sicherheitsprüfung

Vor jedem Merge prüfen:

- keine Inhalte, Prompts oder Antworten in Logs/Audit;
- keine Originaldateiaktion ohne konkreten Auftrag;
- keine ungeprüfte Modellquelle;
- kein paralleler großer Generativlauf;
- keine automatisch bestätigten unsicheren Claims, Projekte oder Muster;
- alle Quellen- und Revisionsfelder vorhanden.
