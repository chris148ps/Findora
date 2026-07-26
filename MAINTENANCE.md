# Dokumentenwartung

## Sicherheitsmodell

Findora führt niemals eine automatische Löschung aus. Jede
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
- Hinweise auf sehr kleinen oder randnahen Text;
- zusammenhängende dunkle Komponenten, Rand-/Eckinhalte und Kontrastinseln.

Die Zustände sind:

- **Sicher leer**: nur bei erfolgreichem Rendering, homogenem Hintergrund und
  gleichzeitig fehlenden Text-, Bild-, Grafik-, Annotations-, Kanten-,
  Komponenten-, Rand- und Kontrastmerkmalen.
- **Vermutlich leer**: sehr hoher Weißanteil und nur minimale visuelle
  Struktur; manuelle Bestätigung bleibt erforderlich.
- **Inhalt erkannt** und **Bildinhalt ohne erkannten Text**: ausdrücklich nicht
  leer.
- **OCR prüfen/OCR ohne Ergebnis**: sichtbarer Inhalt blieb nach der begrenzten
  Nachbearbeitung ohne sicher übernehmbaren Text.
- **Technischer Prüfungsfehler**: Rendering oder Seitenzugriff war nicht
  zuverlässig und ist kein Leerbeleg.

Fehlender Vision- oder Tesseract-Text reicht nie als Leerbeleg.
Leerseitenerkennung und OCR-Erfolg bleiben getrennte Zustände. Eine manuelle
Leer-/Nichtleer-Entscheidung ist an Pfad, Seite und SHA-256 gebunden, trägt
Zeitpunkt und Quelle `manuelle Prüfung` und bleibt bis zu einer
Inhaltsänderung oder einem ausdrücklichen Zurücksetzen geschützt.

Die Schema-Migration setzt frühere rein automatische `Vollständig leer`-
Markierungen transaktional auf **Ungeprüft** zurück. Manuell bestätigte
Entscheidungen bleiben erhalten; ein Migrationsfehler rollt die gesamte
Schemaänderung zurück.

## OCR prüfen und Seitentext

**OCR prüfen** zeigt Seitenvorschau, Status, aktuelle/beste/alternative
OCR-Varianten, Engine, Aufbereitung und Qualitätswerte. Mehrfach ausgewählte
Seiten lassen sich als nicht leer markieren oder sequenziell automatisch
nachbearbeiten; hochauflösende Läufe sind global serialisiert.

Der manuelle Dialog bietet Engine, Sprache, Drehung, 144/300/400/600 dpi sowie
die tatsächlich unterstützten Kontrast-, Binarisierungs-, Hintergrund-,
Begradigungs- und Reinigungsoptionen. 600 dpi ist eine warnpflichtige
Einzelseitenoption. Korrigierter OCR-Text bewahrt die ursprüngliche OCR-Fassung;
vollständig manueller Text wird getrennt gekennzeichnet. Beide landen nur in
SQLite. Für die betroffene Seite werden in einer Transaktion der alte
FTS-Eintrag, Chunks und Embeddings ersetzt; andere Dokumente und das Original
bleiben unverändert.

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
analysiert, automatisch sicher/vermutlich leer und zusätzlich ausdrücklich
manuell als leer bestätigt wurde.
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

## Getrennte Reset-Arten

- **Suchindex neu aufbauen** entfernt nur FTS, Chunks und Embeddings und baut
  sie aus gespeichertem Seitentext wieder auf.
- **OCR und automatische Analysen zurücksetzen** entfernt automatische
  OCR-Qualität, automatische Seitenklassifikationen und Retry-Zustände.
  Manuelle Leer-/Nichtleerentscheidungen und manuell korrigierter oder
  erfasster Text bleiben erhalten. Aktive Dokumente werden neu eingeplant.
- **Vollständigen Dokumentindex löschen** entfernt nach zweifacher Bestätigung
  alle Dokument-, Job-, OCR-, Analyse-, Wartungs- und Suchdaten einschließlich
  manueller Entscheidungen. PDFs, Modelle und Einstellungen bleiben erhalten.

Wartungslisten werden ausschließlich aus aktuellen SQLite-Zeilen rekonstruiert.
Analysezeilen müssen zum aktuellen SHA-256 des Jobs passen; veraltete
pfadbasierte Zeilen erscheinen nicht. Jede Liste bietet Text-/Statusfilter
sowie Alle, Keine und Auswahl umkehren. Bei Duplikaten bleibt dabei mindestens
eine Datei je Hashgruppe geschützt.

In **Leere Seiten** kann die visuelle Analyse außerdem für eine einzelne Seite
gezielt neu gestartet werden. Vorher wird der aktuelle SHA-256 geprüft; die PDF
wird nicht verändert. Die Analyse des betroffenen Dokuments wird neu berechnet,
während manuelle Entscheidungen und manuell erfasster Seitentext erhalten
bleiben.

Alle Wartungszähler werden aus den aktuellen, zum SHA-256 passenden
Analysezeilen neu aggregiert. Die Beziehungen zu Dokument-, OCR- und
Suchindexwerten sowie das genaue Resetverhalten stehen in
[`DOCUMENT_STATUS.md`](DOCUMENT_STATUS.md).
