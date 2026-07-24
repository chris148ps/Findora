# PrivateDocSearch

PrivateDocSearch ist eine native macOS-App für lokale OCR, Indexierung und
semantische Suche in privaten PDF-Beständen. Dokumente, Suchanfragen,
Embeddings und Antworten bleiben auf dem Mac. Es werden weder Ollama noch ein
externer KI-Server oder eine Cloud-KI benötigt.

## Voraussetzungen

- Apple-Silicon-Mac mit mindestens 8 GB Unified Memory
- macOS 14 oder neuer
- Xcode 26 mit installierter Metal-Toolchain
- für die interne Version: OCRmyPDF über Homebrew

```bash
xcodebuild -downloadComponent MetalToolchain
brew install ocrmypdf tesseract-lang poppler
```

PrivateDocSearch erkennt standardmäßig Homebrew unter `/opt/homebrew/bin` und
`/usr/local/bin`. Die App installiert keine Systempakete selbst.

## Build

```bash
swift test
./scripts/build-app.sh
```

MLX enthält Metal-Shader. Deshalb erzeugt `build-app.sh` den produktiven Build
mit Xcode und nicht mit `swift build`. Das Ergebnis liegt unter
`build/PrivateDocSearch.app`.

## Installation

Für die interne, ad-hoc signierte Version:

1. `build/PrivateDocSearch.app` nach `/Applications` kopieren.
2. Die App aus dem Finder öffnen.
3. Falls macOS die interne Signatur beanstandet, im Finder mit Rechtsklick
   **Öffnen** wählen.

Diese interne Version ist nicht notarisiert und setzt OCRmyPDF über Homebrew
voraus. Vor einer externen Verteilung sind Developer-ID-Signierung,
Notarisierung und die Lizenz-/Bundle-Strategie für OCR-Abhängigkeiten separat
abzuschließen.

## Erster Start und Ordnerberechtigung

Unter **Einstellungen** mit **Ordner auswählen** genau den PDF-Stammordner
freigeben. Die Auswahl erfolgt über den macOS-Dateidialog. PrivateDocSearch
speichert ein Security-Scoped Bookmark und stellt die Berechtigung nach einem
Neustart wieder her. Ist ein Volume nicht verbunden oder die Berechtigung
entzogen, wird das sichtbar gemeldet; der Index wird nicht als leer behandelt.

Symlinks, versteckte Dateien, temporäre Download-Dateien und app-eigene
Arbeitsdateien werden nicht verfolgt. Der Ordner wird rekursiv durchsucht.

## OCR

PrivateDocSearch prüft jede PDF seitenweise. Eine bereits brauchbare
Textschicht bleibt unverändert. Für Scan-PDFs läuft OCRmyPDF standardmäßig mit
Deutsch und Englisch, Rotation, Begradigung, ohne PDF/A-Konvertierung und ohne
Bildoptimierung.

OCR schreibt nie direkt in das Original. Erst nach PDF-, Seitenzahl-,
Textschicht- und Hashprüfung ersetzt die App die Datei atomar am selben Ort.
Dateiname und Ordner bleiben gleich. Schlägt ein Schritt fehl, bleibt das
Original erhalten.

Unter **OCR** lassen sich Sprachen und konservative Optionen ändern. OCR und
Indexierung können pausiert und fehlgeschlagene Jobs erneut eingeplant werden.

## Erstindexierung

Nach der Ordnerauswahl startet ein Vollscan. Danach kombiniert die App
Dateisystemhinweise mit einem periodischen Differenzscan. Der persistente
Jobstatus erlaubt die Fortsetzung nach einem Neustart.

Status, Warteschlange und technische Fehler erscheinen unter **Status** und
**Logs**. Inhalte von Dokumenten werden nicht protokolliert.
Das dauerhaft lesbare technische Protokoll liegt unter
`~/Library/Logs/PrivateDocSearch/PrivateDocSearch.log`.

## Modellauswahl

Unter **Modelle** stehen nur fest versionierte, lizenzierte MLX-Modelle aus dem
eingebauten Katalog. Vor der Installation zeigt die App Lizenz,
Downloadgröße und RAM-Einstufung. Jede Datei wird per SHA-256 validiert.

- Embeddings: multilingual E5 Small, 384 Dimensionen
- Antworten: Qwen3 1.7B 4 Bit für 8-GB-Macs empfohlen
- Qwen3 4B 4 Bit nur bei ausreichendem Speicher

Downloads lassen sich pausieren, fortsetzen und abbrechen. Ein
Embedding-Modellwechsel erfordert eine Neuindexierung. Das Sprachmodell wird
erst für eine Antwort geladen und bei Speicherdruck oder nach Inaktivität
entladen.

## Suche und Quellen

Die Suche kombiniert SQLite FTS5 mit lokaler Vektorsuche und führt beide
Ranglisten per Reciprocal Rank Fusion zusammen. Treffer zeigen Dateiname,
Pfad, Seite, Auszug und Relevanz. Eine PDF kann im Finder, in der
Standard-PDF-App oder in der internen PDFKit-Vorschau geöffnet werden.

Für eine formulierte Antwort werden nur die besten lokalen Fundstellen an das
lokale Modell übergeben. Quellen-IDs werden von der App erzeugt und nachher
gegen die Datenbank validiert. Fehlen ausreichende Belege, gibt die App keine
scheinbar belegte Antwort aus.

## Updates

Version 1 enthält keinen automatischen App- oder Online-Katalog-Updater.
App-Updates werden als vollständig neuer, signierter Build installiert.
Modellupdates sind nur über einen neuen eingebauten, fest versionierten
Katalog vorgesehen; eine aktive alte Modellversion bleibt bis zur
erfolgreichen Prüfung einer neuen Version erhalten.

## Fehlerbehebung

Die wichtigsten Prüfungen:

```bash
ocrmypdf --version
tesseract --list-langs
pdftotext -v
pdfinfo -v
xcodebuild -showComponent MetalToolchain -json
```

Bei fehlender Ordnerberechtigung den Stammordner erneut auswählen. Bei
fehlenden OCR-Sprachen `tesseract-lang` installieren. Weitere Fälle stehen in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Deinstallation

1. PrivateDocSearch beenden.
2. Optional den Login-Start in **Einstellungen** vorher deaktivieren.
3. `PrivateDocSearch.app` löschen.
4. Nur wenn Index, Modelle und Einstellungen ebenfalls entfernt werden
   sollen:

```text
~/Library/Application Support/PrivateDocSearch/
~/Library/Logs/PrivateDocSearch/
```

Private PDFs liegen außerhalb dieser Pfade und werden bei der Deinstallation
nicht gelöscht.

## Projektunterlagen

- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`OCR_PIPELINE.md`](OCR_PIPELINE.md)
- [`INDEXING_PIPELINE.md`](INDEXING_PIPELINE.md)
- [`SEARCH_PIPELINE.md`](SEARCH_PIPELINE.md)
- [`MODEL_MANAGER.md`](MODEL_MANAGER.md)
- [`PRIVACY.md`](PRIVACY.md)
- [`SECURITY.md`](SECURITY.md)
- [`TESTING.md`](TESTING.md)
