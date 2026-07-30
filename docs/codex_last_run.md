# Codex-Arbeitsstand

Stand: 30. Juli 2026

## Ausgangszustand

- Branch `main`, Arbeitsbaum vor Beginn sauber, `origin/main` aktuell.
- Ausgangscommit `needd8ca feat: add PDFKit hybrid search and OCR escalation`.
- Baseline: 97 Tests bestanden.
- SQLite-Schema 14, Modellkatalog Schema 1, keine getrennte Wissensschicht.
- Keine produktiven Daten und keine Originaldokumente wurden geöffnet.

## Umsetzung

### Modelle

- Katalog Schema 2 mit capability-basierten Rollen und Zuständen.
- Qwen 3.5 4B MLX 4 Bit als primäres Text-/Wissensmodell.
- Phi-4 Mini Instruct 4 Bit als lokales Prüfmodell.
- Gemma 4 E2B Instruct 4 Bit als experimentelles visuelles Modell.
- Gepinnte Revisionen, Einzeldateigrößen und SHA-256-Prüfsummen.
- Capability-Router, 8-GB-Kontextgrenzen, Speicherdrucksperre,
  priorisierte exklusive Leases, Abbruch, Timeout und Ladefehler-Cooldown.
- Ältere Qwen-Modelle bleiben erhalten.

### Wissensdatenbank

- SQLite-Schema 15 mit lokaler Sicherheitskopie vor einer Bestandsmigration.
- Entitäten, Aliase, Kennungen, Fakten, Beziehungen, Claims, Belege,
  Konflikte, Revisionen, Projekte, Zusammenfassungen, Jobs, Wissenslücken,
  Kommunikation, Statistiken, Trends und Erfahrungswissen.
- Fail-closed JSON- und Quellenvalidierung mit Dokument-, Seiten-, Chunk-,
  Textstellen- und optionaler Bounding-Box-Prüfung.
- Vollständig transaktionale Speicherung; keine Teilpersistenz.
- Idempotente Jobketten bei neuem/geändertem Dokument.
- Sichere Invalidierung: fehlende Quelle zieht einen Claim nur ohne weiteren
  gültigen Beleg zurück.
- begrenzte SQLite-Graphtraversierung und kombinierte
  Wissens-/FTS-/Dateinamen-/Vektorretrieval.

### Kommunikation, Projekte und Erfahrung

- Threadbildung aus Unterhaltungskennung, Reply-Headern sowie Betreff plus
  Teilnehmern; keine reine Betreffzuordnung.
- Dauerhafte E-Mail-/Anhang-/Dokumentverknüpfung.
- deterministische Entitätsauflösung mit Vorrang gespeicherter Negativregeln.
- Projektbewertung verlangt starke Mehrfachsignale; häufiger Name allein wird
  abgelehnt.
- Tabellen und Diagnoseansicht für beleggebundenes Erfahrungswissen.

### Oberfläche

- Einstellungen für automatische Auswahl, Zweitprüfung, experimentelle
  Modelle, Leerlaufentladung und standardmäßig ausgeschaltete automatische
  Downloads.
- Entwicklerbereich mit Übersicht, Projekten, Entitäten, Claims,
  Kommunikationsgraph, Erfahrungswissen und Wartung.
- Wissensfunktion deaktivierbar. Reset nur nach `RESET KNOWLEDGE`; Dokumente,
  OCR und klassischer Suchindex bleiben erhalten.
- Nativer persistenter Antwort-/Quellen-Trenner mit Mindestgrößen,
  Doppelklick-Reset und kompakter Ersatzdarstellung.

## Tests

Der Bestand wurde von 97 auf 112 Tests erweitert. Neue Abdeckung umfasst:

- Katalog und Routing für Qwen/Phi/Gemma,
- 8-GB-Kontextbudget, kritischen Speicherdruck und exklusive Modellwechsel,
- gültige und erfundene Quellen, falsche Seiten, fehlende Belege und
  unzulässige Aussagentypen,
- idempotente abhängige Jobs und vollständige Deaktivierung,
- persistente Entitäten/Fakten/Relationen, Graph und kombinierte Suche,
- Reset-Erhalt des klassischen Dokumentindexes,
- Entitäts-Negativregeln und Projekt-Ablehnung bei häufigem Namen,
- Splitter-Mindestgrößen und kompakte Darstellung.

## Noch extern abzunehmen

- Reale Mehr-GB-Gewichte wurden in normalen Tests nicht heruntergeladen.
- Qwen 3.5, Phi und Gemma benötigen reale Laufzeitabnahmen mit installierten
  Gewichten.
- Verbindliche Modell-RAM-/Zeitmessungen benötigen installierte Gewichte auf
  dem vorhandenen 8-GB-Apple-Silicon-Prüfgerät.
- Gemma bleibt bis zu dieser Abnahme und Lizenzfreigabe experimentell.

## Schutzbestätigung

- keine Originaldokumente verändert,
- keine produktiven App-Daten gelöscht oder migriert,
- keine Modelle oder Buildartefakte in Git aufgenommen,
- keine Versionsänderung,
- kein Tag, kein Release und keine Notarisierung.

## Abschlussprüfungen

- `swift test`: 112 Tests bestanden, 0 Fehler.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`:
  bestanden.
- `swift build -c release`: bestanden.
- `./scripts/check-product-name.sh`: bestanden.
- `./scripts/check-localization.sh`: bestanden.
- `./scripts/build-app.sh release`: bestanden.
- `codesign --verify --deep --strict build/Findora.app`: bestanden
  (Ad-hoc-Signatur, Bundle-ID `de.findora.app`).
- `git diff --check`: bestanden.
- Isolierter Smoke-Test mit `FINDORA_TEST_ROOT` unter dem echten
  macOS-Temporärverzeichnis: bestanden. Vor der ersten UI-Aktion zeigte `lsof`
  ausschließlich Zugriffe auf die isolierte Testdatenbank und keine produktiven
  oder benutzerdefinierten Findora-Daten- oder Modellpfade.
- SQLite im isolierten Testbestand:
  `quick_check = ok`, `integrity_check = ok`, 0 Fremdschlüsselverletzungen.

Das Prüfgerät ist ein Apple-M1-Mac mit 8 GB Unified Memory. Der isoliert
gestartete Leerlaufprozess belegte 69.008 KB RSS. Reale Laufzeitmessungen mit
geladenem Qwen-, Phi- oder Gemma-Modell wurden nicht vorgenommen, weil im
Auftrag keine Zustimmung zu den dafür erforderlichen Multi-GB-Downloads
vorlag. Daher bleiben Modell-RAM, Modellwechsel, visuelle Seitenanalyse und
End-to-End-Modellqualität ausdrücklich als Geräteabnahme offen.

Commit und Push werden im Abschlussbericht des Auftrags mit Hash und Ziel
dokumentiert. Tag, Release, Notarisierung und Versionsänderung sind nicht Teil
dieses Laufs.
