# Changelog

Alle wesentlichen Änderungen an PrivateDocSearch werden hier dokumentiert.
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

### Behoben

- MainActor-Isolationsfehler im Memory-Pressure-Callback behoben; der
  Dispatch-Handler ist nichtisoliert und leitet Zustandsänderungen ausdrücklich
  auf den MainActor weiter.
- Robuster Start-/Stop-Lebenszyklus für die Memory-Pressure-Quelle ergänzt.
- Lesbares lokales Dateiprotokoll für Speicherdruck, Pausierung,
  Modell-Entladung und Fehler ergänzt.

### Bekannte Punkte vor externer Freigabe

- Developer-ID-Signierung und Notarisierung stehen aus.
- Die interne Version setzt Homebrew-OCR voraus und läuft deshalb ohne App
  Sandbox.
- Physische Langzeitabnahme mit großem synthetischem Bestand auf einem
  8-GB-Zielgerät steht aus.
- Version 1 enthält keinen automatischen App-Updater.
