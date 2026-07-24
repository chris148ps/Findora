# OCR-Pipeline

## Standardkonfiguration

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

## Abhängigkeitsprüfung

Beim Start werden ausführbare Dateien nur an freigegebenen Orten gesucht:

1. gespeicherter, vom Nutzer bestätigter Pfad;
2. `/opt/homebrew/bin`;
3. `/usr/local/bin`;
4. definierter App-Bundle-Hilfsordner.

Geprüft werden Version und Funktionsfähigkeit von:

- `ocrmypdf`
- `tesseract`
- `pdftotext`
- `pdfinfo`
- Tesseract-Sprachen aus `--list-langs`

Fehlende Komponenten erzeugen einen sichtbaren Fehler mit Installationshinweis.
Die App führt selbst kein `brew install` aus.

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

## Sicherer Ersetzungsablauf

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

## Parallelität

Auf 8 GB ist die Standardeinstellung ein OCR-Prozess. CPU-Modi:

- sparsam: ein Prozess, niedrige QoS;
- normal: ein Prozess, Utility-QoS;
- schnell: bis zur konfigurierten Obergrenze, höchstens halbe Performance-Cores.

Der Nutzer kann Verarbeitung pausieren. Jobs verbleiben persistent in
`processing_jobs`.

