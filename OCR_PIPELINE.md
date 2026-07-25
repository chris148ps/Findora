# OCR-Pipeline

## Austauschbare OCR-Provider

`OCRProvider` liefert unabhängig von der Engine dasselbe `OCRResult`: Seiten,
Text, Sprache, Qualitätswerte, Laufzeit, Engine und Diagnosen. Chunking,
Embeddings, Suche und SQLite kennen keine enginespezifische Verarbeitung.

Im Standard `Automatisch` wird auf macOS zuerst `VisionOCRProvider` verwendet.
Scheitert Vision, protokolliert `OCRProviderRouter` den Fehler und versucht
`OCRmyPDFProcessor`. Bei expliziter Vision-Auswahl findet kein Fallback statt.
Auf Plattformen ohne Vision führt der Automatikpfad direkt zu Tesseract.

Apple Vision rendert die PDF seitenweise lokal, erkennt Text und
Konfidenzwerte über das Vision Framework und schreibt nur das vereinheitlichte
Ergebnis in SQLite. Es entsteht keine temporäre OCR-PDF und das Original wird
nie verändert.

## OCRmyPDF-Konfiguration

Für OCRmyPDF 17.8.1:

```text
--skip-text
--rotate-pages
--deskew
--output-type pdf
--optimize 0
-l deu+eng
--jobs 1
```

`--output-type pdf` verhindert die standardmäßige PDF/A-Erzeugung.
`--optimize 0` vermeidet standardmäßig Re-Komprimierung. `--skip-text`
bewahrt Seiten mit vorhandener Textschicht. Drehung und Begradigung sind
standardmäßig aktiv, aber einzeln abschaltbar. `--clean` ist optional;
`--clean-final` und `--remove-background` werden wegen möglicher sichtbarer
Artefakte nicht angeboten.

PDF/A ist eine ausdrückliche Nutzeroption. Optimierung 1 ist nur nach
Nutzerwahl aktiv; Optimierung 2/3 wird als potenziell verlustbehaftet
gekennzeichnet.

## Bedarfsgesteuerte Abhängigkeitsprüfung und Installation

Beim ersten Start und im nicht-destruktiven Automatik-/Vision-Modus prüft die
App weder Homebrew noch OCRmyPDF, Tesseract oder Poppler. Die Prüfung beginnt
erst bei:

- ausdrücklicher Auswahl `Tesseract + OCRmyPDF`;
- dauerhaftem OCR-Modus; oder
- einem tatsächlichen Vision-Fehler im Automatikmodus.

Dann werden ausführbare Dateien in dieser Reihenfolge gesucht:

1. `/opt/homebrew/bin`;
2. `/usr/local/bin`;
3. `/usr/bin`;
4. `/bin`;
5. Verzeichnisse aus dem geerbten `PATH`.

Geprüft werden Version und Funktionsfähigkeit von:

- `ocrmypdf`
- `tesseract`
- `pdftotext`
- `pdfinfo`
- `pdftoppm` für die seitenweise Qualitätsmessung
- Tesseract-Sprachen aus `--list-langs`

Für jeden Unterprozess setzt die App denselben expliziten, protokollierten
`PATH`. Deshalb funktioniert die Toolchain auch beim Finder-Start. Erst nach
erfolgreichen Versions- und Sprachtests wird „Bereit“ angezeigt.

Erst nach Nutzerbestätigung darf die App das gefundene Homebrew-Executable direkt
mit den festen Argumenten `install ocrmypdf tesseract-lang poppler` starten.
Benutzereingaben gelangen nicht in Argumente; eine Shell und `sudo` werden
nicht verwendet. Fehlt Homebrew, wird nur die offizielle Installationsanleitung
angeboten.

## Zulässige Eingaben

Nur reguläre `.pdf`-Dateien werden angenommen. Ignoriert werden:

- versteckte Dateien;
- `.part`, `.partial`, `.download`, `.tmp`, `.temp`, `.crdownload`;
- Namen mit Cloud-/Office-Temporärpräfixen wie `~$`;
- app-eigene `.privatedocsearch-ocr-*`-Dateien;
- Symlinks;
- Dateien im Application-Support- oder Models-Verzeichnis.

Eine Datei ist stabil, wenn Größe und Änderungszeit in zwei Prüfungen über
mindestens fünf Sekunden identisch sind, sie exklusiv lesbar ist und ihr
Inhaltshash am Ende der Prüfung übereinstimmt. Nach instabilen Prüfungen folgt
exponentielles Backoff.

## Textschichtprüfung

PDFKit extrahiert seitenweise Text. Eine brauchbare Textschicht liegt vor,
wenn mindestens eine der folgenden Bedingungen erfüllt ist:

- im Dokument mindestens 80 druckbare Zeichen vorhanden sind; oder
- mindestens 70 % der nichtleeren Seiten jeweils mindestens 20 druckbare
  Zeichen enthalten.

Gemischte PDFs werden mit `--skip-text` verarbeitet, wenn mindestens eine
Seite die Schwelle klar unterschreitet. Vollständig brauchbare PDFs werden
nicht an OCRmyPDF übergeben.

## Dokumentidentität und OCR-Modi

Der SHA-256 des unveränderten Originals ist die Dokumentidentität. Pfad,
Dateiname und Zeitstempel sind nur Speicherortdaten. Umbenennen, Verschieben,
identische Kopien und reine Metadatenänderungen verwenden vorhandene Seiten,
Chunks und Embeddings wieder. Ändert sich der Inhalt, wird der neue Hash
verarbeitet und verwaiste alte Indexdaten werden kontrolliert entfernt.

Im Standardmodus liefert Vision den erkannten Text direkt; bei Tesseract wird
die validierte OCR-Ausgabe nur gelesen und anschließend gelöscht. Seiten und
Index entstehen aus demselben in SQLite gespeicherten OCR-Text. Im optionalen
persistenten Modus wird unabhängig von der gewählten Engine immer OCRmyPDF
verwendet und es gilt zusätzlich der folgende
Ersetzungsablauf:

1. Eingabe-Metadaten, SHA-256 und Seitenzahl erfassen.
2. Temporäre Ausgabe im selben Ordner erzeugen, damit der spätere Austausch
   atomar auf demselben Volume möglich ist.
3. OCRmyPDF ohne Shell-Interpolation über `Process.arguments` starten.
4. Abbruch beendet den Prozess kontrolliert.
5. Ausgabe validieren:
   - `%PDF-`-Signatur;
   - PDFKit kann das Dokument öffnen;
   - Seitenzahl entspricht der Eingabe;
   - jede Seite kann geladen werden;
   - eine Textschicht wurde hinzugefügt oder war bereits vorhanden;
   - Ausgabe ist nicht leer;
   - `pdfinfo` meldet keinen Strukturfehler.
6. Original erneut hashen. Bei Abweichung Ausgabe verwerfen und neuen Job
   planen.
7. Mit `FileManager.replaceItemAt` atomar ersetzen. Keine vorherige Löschung.
8. Ergebnis erneut validieren und Status persistieren.

Wenn der atomare Austausch fehlschlägt, bleibt das Original erhalten.
Temporäre Dateien tragen ein eindeutiges App-Präfix und werden nur innerhalb
des gewählten Ordners und nur nach Alters-/Jobabgleich entfernt.

## Qualitätsprüfung

Für jede Seite werden Engine-Konfidenz, Zeichen- und Wortzahl,
ungewöhnliche Zeichen, verdächtig beschädigte Wörter, erkannte Sprache,
Leerseitenindikator und Bild-/Text-Verhältnis gespeichert. Daraus entsteht „Gut“,
„Prüfen“ oder „Wahrscheinlich fehlgeschlagen“. Tesseract liefert seine
Konfidenz über TSV, Vision über erkannte Textbeobachtungen; beide durchlaufen
denselben `OCRQualityEvaluator`. Bei wahrscheinlich
fehlgeschlagenen Seiten ist genau ein zweiter Versuch mit Rotation,
Begradigung und 300-dpi-Übersampling im Tesseract-Pfad zulässig; nur die besser bewertete,
vollständig validierte Variante wird verwendet.

## Parallelität

Auf 8 GB ist die Standardeinstellung ein OCR-Prozess. CPU-Modi:

- sparsam: ein Prozess, niedrige QoS;
- normal: gewählte Parallelität, User-Initiated-QoS;
- schnell: bis zur konfigurierten Obergrenze, höchstens halbe Performance-Cores.

Der Nutzer kann Verarbeitung pausieren. Jobs verbleiben persistent in
`processing_jobs`.
