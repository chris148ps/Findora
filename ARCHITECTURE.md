# Findora – Architektur und Umsetzungsplan

Stand: 24. Juli 2026

## Ziel und Leitplanken

Findora ist eine eigenständige, native macOS-App. Sie verarbeitet
ausgewählte PDF- und exportierte E-Mail-Bestände ausschließlich lokal.
Dokumente und Mailquellen werden weder
umbenannt, verschoben noch gelöscht. Eine inhaltliche Änderung ist nur als
sicher validierter, atomarer OCR-Ersatz erlaubt.

Die Anwendung ist für Apple Silicon ab 8 GB Unified Memory ausgelegt. Sie
benötigt weder Ollama noch Docker, einen externen LLM-Server oder eine
Cloud-KI.

## Mindestversion macOS 14

Das Deployment Target ist macOS 14 (Sonoma):

- `mlx-swift-lm` 3.x und MLX Swift setzen macOS 14 voraus.
- Swift Concurrency und moderne SwiftUI-APIs stehen in einer stabilen,
  einheitlichen Basis zur Verfügung.
- `SMAppService` ist seit macOS 13 verfügbar.
- PDFKit, Security-Scoped Bookmarks, FSEvents und SQLite sind Systemframeworks.

macOS 13 würde wegen MLX keinen funktionalen Vorteil bringen und einen zweiten
Inferenzpfad erzwingen. Eine Anhebung auf macOS 15 ist nicht erforderlich.

## Modulgrenzen

Die Swift-Pakete und Targets folgen diesen Abhängigkeiten:

```text
FindoraApp (SwiftUI/AppKit)
    ├── FindoraCore
    │   ├── FolderAccess
    │   ├── FileObservation
    │   ├── OCR
    │   ├── PDFExtraction
    │   ├── Indexing
    │   ├── Search
    │   ├── MailImport
    │   ├── StorageMigration
    │   ├── Persistence
    │   ├── Models
    │   └── Logging
    └── FindoraMLX
        ├── MLXLLM
        ├── MLXEmbedders
        └── ModelRuntime
```

`FindoraCore` enthält keine UI-Abhängigkeit und lässt sich ohne
Modelldownload testen. Protokolle kapseln veränderliche Implementierungen:

- `FolderAccessProviding`
- `DocumentScanning`
- `FileStabilityChecking`
- `OCRProcessing`
- `PDFTextExtracting`
- `Chunking`
- `DocumentIndexing`
- `EmbeddingProviding`
- `VectorSearching`
- `AnswerGenerating`
- `ModelManaging`
- `AppLogging`

Nebenläufige, zustandsbehaftete Dienste werden als Swift Actors implementiert.
Die UI beobachtet ausschließlich einen `@MainActor`-App-Zustand.

## Inferenzbackend

### Entscheidung: MLX Swift

Primär wird `mlx-swift-lm` hinter `AnswerGenerating` und
`EmbeddingProviding` eingesetzt.

Vorteile:

- nativ für Apple Silicon und Metal;
- Swift-Integration ohne separaten Prozess oder Server;
- LLM- und Embedder-Laufzeiten im selben gepflegten Paket;
- Modelle können aus lokalen Verzeichnissen geladen und vollständig entladen
  werden;
- MIT-Lizenz für MLX Swift und MLX Swift LM.

`llama.cpp` bleibt ein möglicher späterer Adapter. Es ist ebenfalls MIT-lizenziert
und Metal-fähig, würde aber eine C/C++-Bridge, einen zweiten Modelltyp (GGUF)
und zusätzliche Distributions- und Speicherpfade einführen. Beides parallel in
Version 1 zu integrieren wäre unnötig.

MLX wird nur in einem App-Target gelinkt. Dadurch wird vermieden, dass zwei
Kopien der MLX-Laufzeit im selben Prozess entstehen.

## Embeddingmodell

Standard ist `mlx-community/multilingual-e5-small-mlx`:

- 94 Sprachen einschließlich Deutsch und Englisch;
- 384 Dimensionen und kompakter Speicherbedarf;
- MIT-Lizenz;
- query/document-Präfixe sind für Retrieval definiert;
- lokale MLX-Inferenz auf dem 8-GB-Zielgerät.

Der Modellkatalog pinnt Modell-ID, Revision, Dateiliste und SHA-256-Werte.
Ein Modellwechsel erzeugt einen neuen Indexstand. Der alte Index bleibt bis
zum erfolgreichen Neuaufbau aktiv.

## Antwortmodelle

Der Erstkatalog enthält nur explizit geprüfte MLX-Modelle:

- ein 2B–3B-Modell in 4 Bit als empfohlene 8-GB-Option;
- Qwen3 4B MLX 4 Bit als obere kompatible Option;
- 7B–8B nur experimentell und auf 8 GB standardmäßig gesperrt.

Modelle werden nicht gebündelt. Katalogeinträge enthalten Lizenz, Revision,
Größe, Hashes, Kontextgrenzen und realistische RAM-Schätzungen. Nicht
ausfüllbare Platzhalter gelten nicht als installierbare Modelle.

## Speicherbudget

Vor Aktivierung wird geschätzt:

```text
Laufzeitbedarf =
  Modellgewichte
  + Quantisierungs-/Laufzeit-Overhead
  + KV-Cache (Layer × KV-Heads × Head-Dimension × Tokens × Datentyp × 2)
  + Prompt-/Arbeitsbuffer
  + Embedder (falls gleichzeitig geladen)
  + Sicherheitsreserve
```

Auf 8 GB bleiben mindestens 2,5 GB für macOS und andere Prozesse reserviert.
Kontextlängen werden deshalb auf dem Mindestgerät konservativ begrenzt. Das
LLM wird erst bei einer Frage geladen und standardmäßig nach zehn Minuten
Inaktivität oder bei kritischem Speicherdruck entladen. OCR und LLM laufen
standardmäßig nicht gleichzeitig.

## Persistenz

Die Datenbank liegt unter:

`~/Library/Application Support/Findora/Findora.sqlite3`

Modelle liegen unter:

`~/Library/Application Support/Findora/Models/`

Logs liegen unter:

`~/Library/Logs/Findora/`

Datenspeicher und Modellspeicher können unabhängig auf ein vom Benutzer
gewähltes lokales Volume gelegt werden. Sicherheits- und Umschaltinvarianten
stehen in `STORAGE_ARCHITECTURE.md`, das Schema in `DATABASE_SCHEMA.md`.

Die Datenbank nutzt WAL, Foreign Keys, versionierte Transaktionen und FTS5.
Das Schema enthält:

- `documents`
- `document_locations`
- `pages`
- `chunks`
- `chunks_fts` (FTS5)
- `chunk_embeddings`
- `processing_jobs`
- `ocr_results`
- `index_state`
- `embedding_models`
- `llm_models`
- `model_downloads`
- `settings`
- `errors`
- `search_history`
- `source_bookmarks`
- `schema_migrations`
- `organizations`, `communication_partners`, `projects`
- `document_relations`, `mail_relations`
- `document_analysis_versions`, `analysis_upgrade_jobs`

Statuszähler werden nicht persistiert. `processing_jobs` liefert exklusive
aktuelle Pfadzustände; `documents` und `pages.text_source` liefern die
Dokument- und Seitenklassifikation, `chunks` und `chunk_embeddings` die
Suchindexeinheiten. Eine einzelne SQLite-Snapshotabfrage rekonstruiert alle
Werte. Details und Invarianten stehen in `DOCUMENT_STATUS.md`.

Dokumentidentität und Dateipfad sind getrennt. Der SHA-256-Inhaltshash
identifiziert Inhalte; `document_locations` erhält mehrere reale Pfade für
doppelte Inhalte. Umbenennen und Verschieben aktualisieren nach Hashabgleich
den Pfad, ohne Chunks neu zu erzeugen.

E-Mail-Identität, Quellenzuordnung und Anhangsidentität sind ebenfalls
getrennt. `MailImportService` streamt Quellen; Mail, PDF und Anhang teilen
sich Chunk-, FTS- und Embeddingpipeline.

Migrationen 11 und 12 ergänzen den lokalen Kommunikationsgraphen sowie
unabhängige Analyseversionen je Dokument. Fehlende Personen- und
Projektanalysen werden inkrementell über fortsetzbare Jobs ergänzt; OCR,
Embeddings und vollständige Neuindexierungen bleiben ausdrücklich gestartete
Wartungsaktionen. Details stehen in `docs/COMMUNICATION_GRAPH.md` und
`docs/DATABASE_MIGRATIONS.md`.

Embeddings werden als normalisierte Float32-BLOBs in SQLite gespeichert.
Version 1 verwendet eine in-process, blockweise Kosinus-Suche. Das ist
distributionssicher und für einen privaten Bestand kontrollierbar. Das
`VectorSearching`-Protokoll erlaubt später HNSW, ohne Schema oder UI neu zu
entwerfen.

## Ordnerzugriff und Sandbox

Die App wird sandboxfähig mit folgenden minimalen Berechtigungen gebaut:

- App Sandbox;
- user-selected read/write;
- app-scoped bookmarks;
- ausgehende Netzwerkverbindungen ausschließlich für explizite
  Modelldownloads.

Der Nutzer wählt den Ordner über `NSOpenPanel`. Die App speichert ein
Security-Scoped Bookmark. Beim Start wird es mit Stale-Erkennung aufgelöst,
erneuert und nur für die Dauer notwendiger Arbeit aktiviert.

Fehlerzustände unterscheiden:

- Bookmark fehlt oder wurde entzogen;
- Ziel wurde verschoben/umbenannt und Bookmark ist stale;
- Volume ist nicht eingebunden;
- Netzwerkpfad ist nicht erreichbar;
- Cloud-Platzhalter ist nicht lokal materialisiert;
- POSIX-/Sandbox-Zugriff ist verweigert.

Keiner dieser Zustände wird als leerer Ordner interpretiert; insbesondere
werden Indexeinträge bei einem vorübergehend nicht erreichbaren Stammordner
nicht als gelöscht markiert.

## Beobachtung und Hintergrundarbeit

Die App kombiniert:

1. FSEvents für schnelle Hinweise;
2. einen rekursiven Differenzscan (Standard: fünf Minuten);
3. persistente Jobs in SQLite.

FSEvents sind ein Hinweis, keine alleinige Wahrheitsquelle. Scans verhindern
Symlink-Schleifen anhand der Resource-ID/Volume-ID und folgen Symlinks
standardmäßig nicht.

Version 1 führt die Pipeline im App-Prozess aus. `MenuBarExtra` hält
Steuerbarkeit und Status sichtbar, wenn das Hauptfenster geschlossen ist. Der
Nutzer kann optional `SMAppService.mainApp` als Login Item aktivieren.
Ein separater XPC-/LaunchAgent-Prozess wird erst eingeführt, wenn Messungen
zeigen, dass Wiederanlauf bei vollständig beendeter App erforderlich ist.
Diese Entscheidung vermeidet Bookmark- und Zustandsduplizierung. „App
beenden“ stoppt alle Arbeit kontrolliert; „Fenster schließen“ nicht.

## OCR-Sicherheit

OCR läuft niemals direkt auf das Original. Der Ablauf ist:

1. Stabilität und lokale Verfügbarkeit prüfen;
2. Eingabe-Hash und Seitenzahl erfassen;
3. Ausgabe in einer app-eigenen temporären Datei erzeugen;
4. Ausgabe mit PDFKit/`pdfinfo`, Seitenzahl, Dateigröße und extrahierbarem
   Text validieren;
5. vor dem Ersetzen prüfen, dass das Original noch denselben Hash besitzt;
6. Original und Ausgabe auf demselben Volume atomar austauschen;
7. Ergebnis erneut hashen und Jobstatus transaktional speichern.

Jeder Fehler vor Schritt 6 lässt das Original unverändert. Temporäre Reste
werden beim nächsten Start anhand eines app-eigenen Präfixes bereinigt.
Details stehen in `OCR_PIPELINE.md`.

## Prompt- und Quellenregeln

Dokumentauszüge werden als nicht vertrauenswürdige Daten abgegrenzt. Ein
festes Systemprompt verbietet, Anweisungen aus Dokumenttext auszuführen.
Quellen-IDs werden von der App vergeben. Das Modell kann nur diese IDs
referenzieren; Dateiname und Seitenzahl werden nach der Generierung aus der
Datenbank ergänzt. Unbekannte IDs werden verworfen.

Bei zu niedriger Retrieval-Güte wird kein LLM-Freitext als belegte Antwort
ausgegeben, sondern die definierte Keine-Belege-Meldung.

## Meilensteine und Gates

1. **Grundlage:** Paket, App-Bundle, Protokolle, Datenbankmigrationen.
2. **Dokumentzugriff:** Bookmark, rekursiver Scanner, stabile Jobs.
3. **OCR/Extraktion:** sichere temporäre Pipeline, PDFKit/Poppler, Tests.
4. **Index:** Chunking, FTS5, inkrementelle Updates.
5. **Semantik:** MLX-Embedder, blockweise Vektorsuche, Hybrid-Ranking.
6. **Antwort:** MLX-LLM, Quellenvalidierung, RAM-Lifecycle.
7. **Modelle:** Katalog, Download, Hash, Aktivierung, Rollback.
8. **Produkt-UI:** Suche, Status, OCR, Modelle, Einstellungen, Log.
9. **Hintergrund:** MenuBarExtra, Login Item, Wiederaufnahme.
10. **Abnahme:** künstliche PDFs, Tests, 8-GB-Messung, signiertes App-Bundle.

Nach jedem Gate werden Build und Tests ausgeführt. Ein Gate gilt nicht als
fertig, wenn nur ein UI-Platzhalter ohne funktionalen Dienst existiert.

## Persistente UI-Zustände

Fachliche Dokumentzustände bleiben in SQLite. Erfolgreiche Transaktionen
publizieren gedrosselte Statusereignisse; ein 30-Sekunden-Abgleich ist nur ein
Sicherheitsnetz. `processing_sessions` hält den sichtbaren Arbeitsfortschritt
über Jobgrenzen und Neustarts stabil. `model_states` trennt Installation,
Aktivierung und flüchtigen RAM-Ladezustand. Sprache und Erscheinungsbild liegen
als Einstellungen in derselben lokalen Datenbank.

## Risiken

- **Sandbox und Homebrew:** Apple Vision benötigt keine externen Prozesse.
  Nur der ausdrücklich gewählte Tesseract- oder persistente OCR-Pfad verwendet
  Homebrew-Werkzeuge nach Nutzerbestätigung. Für eine
  Mac-App-Store-Distribution müssen OCR-Komponenten gebündelt oder die
  Distributionsstrategie angepasst werden.
- **OCR-Lizenzen:** OCRmyPDF selbst ist MPL-2.0; mitgelieferte Komponenten
  haben eigene Lizenzen. Ein Bundle benötigt eine vollständige
  Lizenzinventur. Die erste interne Version installiert nichts global.
- **Modellartefakte:** Modell- und Code-Lizenz sind getrennt zu prüfen.
  Katalogeinträge ohne klare Lizenz und reproduzierbare Hashes werden nicht
  veröffentlicht.
- **8-GB-Grenze:** 4B-Modelle sind trotz 4-Bit-Weights durch KV-Cache und
  Arbeitsbuffer knapp. Der Kontext wird begrenzt und OCR pausiert.
- **Cloud-Platzhalter:** Es gibt keine einheitliche Provider-API. Nicht lokal
  lesbare Dateien werden als wartend angezeigt, aber nicht automatisch
  heruntergeladen.
- **Seitenöffnung:** PDFKit kann eine Seite anzeigen; externe Viewer
  akzeptieren keine zuverlässige, allgemeine Seitennavigation. Die App öffnet
  deshalb die Quelle intern auf der Seite und bietet zusätzlich „PDF öffnen“.

## Primärquellen

- [MLX Swift](https://github.com/ml-explore/mlx-swift)
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Apple: App Sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [OCRmyPDF 17.8.1 cookbook](https://ocrmypdf.readthedocs.io/en/latest/cookbook.html)
