# Changelog

Alle wesentlichen Änderungen an Findora werden hier dokumentiert.
Das Projekt verwendet vor einer externen Freigabe keine impliziten Releases
oder Tags.

## Unreleased

### Hinzugefügt

- native SwiftUI-App für macOS 14 auf Apple Silicon;
- persistente Security-Scoped-Bookmark-Ordnerauswahl;
- rekursiver PDF-Scanner mit Dateisystembeobachtung und Differenzscan;
- sichere, atomare OCRmyPDF-Pipeline mit Deutsch/Englisch;
- seitenweise PDFKit-Extraktion und seitengebundenes Chunking;
- SQLite-WAL-Datenbank mit FTS5, persistenten Jobs und Fehlerstatus;
- lokale MLX-E5-Embeddings und blockweise Vektorsuche;
- hybride Rangfolge aus Volltext und Vektoren;
- lokale Qwen3-Antwortgenerierung mit validierten Quellen;
- fest versionierter Modellkatalog mit Datei-SHA-256-Prüfung;
- pausierbare und fortsetzbare Modelldownloads;
- RAM-Kompatibilitätsprüfung, Idle-Unload und Speicherdruck-Reaktion;
- Status-, OCR-, Modell-, Einstellungs- und Log-Oberflächen;
- optionale Menüleistensteuerung und Login-Item;
- automatisierte Core-, OCR-, Index- und Opt-in-MLX-Tests;
- Architektur-, Datenschutz-, Sicherheits-, Test- und Betriebsdokumentation.
- produktiver lokaler Agentendienst für die persistente Wissensjobkette;
- Qwen-3.5-Extraktion mit unabhängiger Phi-4-Mini-Prüfung und gemeinsamer
  Exklusivsperre für große generative Laufzeiten;
- Schema 16 mit Agentenläufen, Audit-Log und erweiterbarer lokaler Ontologie;
- beleggebundene Konflikt-, Kommunikations-, Projekt-, Zusammenfassungs- und
  Erfahrungsfolgestufen;
- Agentenmonitor und sichtbare Antwortklassen;
- tatsächliches, ausdrücklich aktivierbares capability-basiertes
  Downloadrouting für empfohlene Wissensmodelle.
- unsichere `model_inference`-Aussagen werden nicht als Fakten oder Relationen
  gespeichert, sondern ausschließlich als auflösbare Wissenslücken geführt.

### Behoben

- MainActor-Isolationsfehler im Memory-Pressure-Callback behoben; der
  Dispatch-Handler ist nichtisoliert und leitet Zustandsänderungen ausdrücklich
  auf den MainActor weiter.
- Robuster Start-/Stop-Lebenszyklus für die Memory-Pressure-Quelle ergänzt.
- Lesbares lokales Dateiprotokoll für Speicherdruck, Pausierung,
  Modell-Entladung und Fehler ergänzt.

### Geändert

- Technische Produktidentität vollständig auf Findora vereinheitlicht:
  Bundle-ID `de.findora.app`, SwiftPM-Module und Targets, Quell- und
  Testverzeichnisse, Entitlements, Datenbank-, Application-Support-,
  Log-, URL-, Queue- und Diagnosekennungen.
- Lokale Daten werden unter `~/Library/Application Support/Findora/`,
  Protokolle unter `~/Library/Logs/Findora/Findora.log` angelegt.
- Keine Altpfad- oder Einstellungsmigration, da vor der Umstellung keine
  produktiven Installationen existieren.

### Bekannte Punkte vor externer Freigabe

- Developer-ID-Signierung und Notarisierung stehen aus.
- Nur ausdrücklich gewähltes Tesseract oder dauerhaftes OCR benötigt die
  externe Homebrew-OCR-Werkzeugkette; der Apple-Vision-Standardpfad kommt
  ohne diese Komponenten aus. Der optionale externe Werkzeugpfad läuft
  weiterhin ohne App Sandbox.
- Physische Langzeitabnahme mit großem synthetischem Bestand auf einem
  8-GB-Zielgerät steht aus.
- Version 1 enthält keinen automatischen App-Updater.
