# Dokumentenwartung

## Sicherheitsmodell

PrivateDocSearch führt niemals eine automatische Löschung aus. Jede
verändernde Aktion benötigt eine konkrete Auswahl und einen
Bestätigungsdialog. Ganze Dateien und die alte Fassung einer seitenweise
bereinigten PDF werden ausschließlich in den macOS-Papierkorb verschoben.

Vor jeder Aktion wird der aktuelle SHA-256 erneut mit dem bei der Analyse
gespeicherten Originalhash verglichen. Hat ein anderer Prozess die Datei
inzwischen verändert, bricht die Aktion ab. Mehrdateiaktionen werden vorab
vollständig geprüft. Schlägt Papierkorb oder Datenbankaktualisierung fehl,
stellt die App bereits verschobene Dateien an ihren ursprünglichen Positionen
wieder her.

## Leerseitenerkennung

Die Analyse rendert jede Seite verkleinert und speichert nur technische
Messwerte:

- Renderstatus und Bildgröße;
- Weißanteil, dunkle Pixel, Varianz, Kantenanteil und Kontrast;
- Zeichen- und Wortanzahl sowie vorhandene OCR-Konfidenz;
- eingebettete Bild-/Grafikobjekte;
- Annotationen als Schutz für Stempel, Unterschriften und Formularinhalte;
- Hinweise auf sehr kleinen oder randnahen Text.

Die Zustände sind:

- **Vollständig leer**: praktisch vollständig weiß, ohne Text-, Kanten-,
  Bild- oder Annotationsstruktur.
- **Vermutlich leer**: sehr hoher Weißanteil und nur minimale visuelle
  Struktur; manuelle Bestätigung bleibt erforderlich.
- **Bild ohne erkannten Text**: sichtbares Bild/Grafikobjekt ohne Text. Dieser
  Zustand ist ausdrücklich nicht leer.
- **OCR überprüfen**: beispielsweise Trennlinie, Stempel, Unterschrift,
  kontrastarme Struktur oder nicht erklärbare dunkle Pixel.
- **Technischer Fehler**: Rendering oder Seitenzugriff war nicht zuverlässig.

Fehlender Vision- oder Tesseract-Text reicht nie als Leerbeleg. Die Analyse
verwendet den ohnehin vorhandenen OCR-Text und startet keine zweite OCR.

## Einzelne Seiten entfernen

Nur manuell als leer bestätigte Kandidaten sind auswählbar. Die App:

1. prüft Originalhash und Seitenzahl;
2. erzeugt eine neue PDF aus allen zu erhaltenden Seiten;
3. öffnet die neue Datei erneut;
4. prüft Seitenzahl, Reihenfolge, Text, Seitengröße, Annotationen und
   deterministische Renderfingerabdrücke;
5. prüft den Originalhash unmittelbar vor dem Austausch erneut;
6. tauscht beide Dateien atomar aus;
7. verschiebt die vollständige alte PDF in den Papierkorb;
8. entfernt nur die alte Dokumentversion aus SQLite und indexiert die neue
   PDF gezielt.

Bei einem Fehler vor Abschluss bleibt beziehungsweise wird die ursprüngliche
PDF wiederhergestellt.

## Vollständig leere PDFs

Eine PDF erscheint nur dann in **Leere PDFs**, wenn jede Seite vollständig
analysiert und jede Seite als vollständig oder vermutlich leer eingestuft ist.
Bildseiten, Prüffälle, technische Fehler und manuell als nicht leer markierte
Seiten schließen die PDF aus. Die Benutzeraktion verschiebt die ausgewählten
Dateien in den Papierkorb und bereinigt anschließend ihre Suchdaten.

## SHA-256-Duplikate

Eine Duplikatgruppe entsteht ausschließlich aus demselben SHA-256 des
Originaldokuments. Gleicher Dateiname, gleiche Größe, ähnlicher OCR-Text oder
ähnliche Seiten sind kein Duplikatnachweis.

Die App zeigt alle Speicherorte, Größe, Änderungsdatum und eine unverbindliche
Behalten-Empfehlung. Der Benutzer legt fest, welche Datei erhalten bleibt.
Mindestens ein Speicherort je Hashgruppe muss erhalten bleiben.

## Index und Embeddings

Nach einer Seitenentfernung wird nur die betroffene PDF neu verarbeitet.
Nach dem Verschieben ganzer Dateien werden deren Volltext-, Chunk- und
Embeddingdaten entfernt, sofern kein weiterer Speicherort desselben Dokuments
existiert. **Embeddings neu erzeugen** baut den Suchindex aus dem bereits
gespeicherten Seitentext auf; **Dokumentindex zurücksetzen** verändert keine
PDF-Datei.
