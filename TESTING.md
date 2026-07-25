# Teststrategie

## Schneller Testlauf

```bash
swift test
```

Die automatisierten Tests verwenden ausschließlich künstlich erzeugte
Textdateien und PDFs. Private Dokumente sind nicht erforderlich.

Abgedeckt sind:

- rekursiver Scan, Ausschlüsse und Symlink-Verhalten;
- temporäre OCR-Namen;
- Seitenextraktion und seitengebundenes Chunking;
- deterministischer Fallback-Embedder;
- regelbasierte Suchplanung für Pflichtentität, Thema und UND-Verknüpfung;
- strikte Modellplanvalidierung einschließlich Fallback und SQL-Abweisung;
- Pflichtfilter für Name in digitalem Text, OCR-Text und Dateiname;
- Re-Ranking für selben Chunk und getrennte Chunks desselben Dokuments;
- Ausschluss von Dokumenten ohne Pflichtperson oder Themenbeleg ohne
  künstliches Auffüllen;
- Quellen-ID-Validierung und begrenzter Sitzungskontext;
- Erkennung eines gemischten E5-/Fallback-Embeddingindex;
- SQLite-Migration, Indexierung, hybride Suche, Umbenennen, Verschieben,
  identische Kopie, Metadatenänderung, Inhaltsänderung und Löschen;
- unverändertes Original bei korrupter OCR-Eingabe;
- reale OCRmyPDF-Verarbeitung einer synthetischen Scan-PDF im
  nicht-destruktiven und persistenten Modus;
- reale Apple-Vision-OCR einer synthetischen Scan-PDF ohne Originaländerung;
- Automatikmodus ohne Tesseract, Vision-zu-Tesseract-Fallback und erzwungenes
  OCRmyPDF im dauerhaften Modus;
- identische Suchresultate und Datenbankaggregation für beide OCR-Provider;
- Moduswechsel ohne automatische Neuverarbeitung;
- Finder-sichere Toolauflösung und sicherer Abbruch ohne Homebrew;
- seitenweise OCR-Qualität einschließlich Tesseract-Konfidenz;
- Erkennung einer älteren installierten Modellversion;
- ereignisgetriebener Dokumentenstatus unter 500 ms;
- konsistente OCR-/Job-/Chunk-/Embedding-/Duplikatzähler;
- persistierte Pause und identische Statusrekonstruktion nach Datenbank-Neustart;
- genau vier primäre Dokumentenstatus-Kennzahlen;
- visuelle Leerseitenerkennung für vollständig leere Seiten, Trennseiten,
  Bildseiten, Unterschriften, Stempel, kontrastarme Seiten und kleine
  Randnotizen;
- getrennte Erkennung vollständig leerer und gemischter PDFs;
- bestätigte Einzelseitenentfernung mit PDF-, Reihenfolge- und
  Reindexierungsprüfung;
- SHA-256-Duplikate über verschiedene Namen und Speicherorte sowie Ausschluss
  gleichnamiger Dateien mit anderem Inhalt;
- Papierkorb- und Datenbankaktualisierung einschließlich vollständigem
  Rollback bei einem simulierten Mehrdateifehler;
- Vollständigkeit, Revisionen und Hashes des Modellkatalogs;
- Hardware-Einstufung des Katalogs.

## Reale MLX-Integration

Die MLX-Integration benötigt die Xcode-Metal-Toolchain und muss über Xcode
gebaut werden:

```bash
xcodebuild -downloadComponent MetalToolchain
./scripts/test-mlx.sh
```

Der Opt-in-Test lädt das fest gepinnte E5-Modell in ein temporäres Verzeichnis,
prüft alle Hashes, lädt es mit MLX und erzeugt normalisierte
384-dimensionale Embeddings. Das temporäre Modell wird nach dem Test entfernt.
Der Test ist opt-in, weil er rund 252 MB Netzwerktransfer benötigt.

Der getrennte Antwortmodelltest lädt rund 984 MB, prüft alle Dateien und
erzeugt mit Qwen3 1.7B 4 Bit eine kurze Antwort:

```bash
./scripts/test-llm.sh
```

## App-Build prüfen

```bash
./scripts/build-app.sh
codesign --verify --deep --strict build/PrivateDocSearch.app
```

Danach manuell:

1. App auf Apple Silicon starten.
2. Einen ausschließlich synthetischen Testordner wählen.
3. App neu starten und Bookmark-Wiederherstellung prüfen.
4. Text-PDF, Scan-PDF, gemischte PDF und beschädigte PDF hinzufügen.
5. Während eines Kopiervorgangs Stabilitätsprüfung beobachten.
6. OCR pausieren, fortsetzen und App während eines Jobs neu starten.
7. Umbenennen, Verschieben, Ändern und Löschen erkennen lassen.
8. Identische Kopie und reine Zeitstempeländerung ohne Neuindexierung prüfen.
9. Beide OCR-Modi und einen Moduswechsel prüfen.
10. E5 und ein kompatibles Antwortmodell installieren.
11. Volltext-, semantische und gemischte Fragen prüfen.
12. Quellen gegen PDF-Seiten verifizieren.
13. Antwort abbrechen und Entladen bei Speicherdruck/Inaktivität prüfen.
14. Volume aushängen; der Index darf nicht als leer behandelt werden.
15. Dokumentenstatus auf vier Hauptkennzahlen und eingeklappte technische
    Details prüfen.
16. Wartungslisten durchsuchen, sortieren, Seiten vorschauen und Entscheidungen
    zurücksetzen.
17. Nur mit synthetischen PDFs Papierkorb- und Seitenaustauschdialoge prüfen.

Der Memory-Pressure-Pfad lässt sich ohne echten Speichermangel kontrolliert
beim App-Start auslösen:

```bash
PRIVATEDOCSEARCH_SIMULATE_MEMORY_PRESSURE=critical \
  PRIVATEDOCSEARCH_DISABLE_DOCUMENT_ACCESS=1 \
  build/PrivateDocSearch.app/Contents/MacOS/PrivateDocSearch
```

Der Regressionstest leitet dasselbe Ereignis von einer Utility-Queue auf den
MainActor weiter. Im Log müssen das kritische Ereignis und die erfolgreiche
Hintergrund-Weiterleitung erscheinen; `_dispatch_assert_queue_fail` oder
`SIGTRAP` dürfen nicht auftreten. Der zweite Schalter verhindert für diesen
Diagnoselauf ausdrücklich Bookmark-Wiederherstellung, Ordnerscan und jeden
PDF-Zugriff.

## Abnahme auf 8 GB

Vor einer externen Version sind Langzeittests mit einem großen synthetischen
Bestand nötig. Zu messen sind Peak-RAM, Speicherdruck, OCR/LLM-Ausschluss,
Erstimport-Fortsetzung, Modellwechsel mit Reindexierung und Stabilität nach
mehreren Neustarts.
