# Indexierungs-Pipeline

## Erkennung

FSEvents stößt einen begrenzten Differenzscan an. Unabhängig davon läuft
standardmäßig alle fünf Minuten ein vollständiger rekursiver Vergleich. Ein
Scan ist generationenbasiert: Nur wenn der Stammordner während des gesamten
Scans erreichbar war, dürfen vorher bekannte Pfade als gelöscht markiert
werden.

Pro Datei werden kanonischer Pfad, relativer Pfad, Resource-ID, Volume-ID,
Größe, Änderungszeit und SHA-256 gespeichert. Größe und Änderungszeit dienen
als schneller Vorfilter; allein lösen sie keine OCR aus.

## Dokumentidentität

- gleicher Pfad und gleicher Hash: unverändert;
- gleicher Pfad und neuer Hash: neue Dokumentversion;
- neuer Pfad und bekannter Hash: Umbenennung, Verschiebung oder Duplikat;
- verschwundener Pfad: Location gelöscht markieren;
- letzter Pfad eines Inhalts verschwunden: Dokument, FTS-Zeilen, Chunks,
  OCR-Qualität und Embeddings werden nach dem Scan kontrolliert entfernt.

Mehrere Pfade für denselben Hash werden als Speicherorte eines Dokuments
geführt. Seiten, Chunks, OCR-Text und Embeddings werden nicht dupliziert.

## Textextraktion

PDFKit extrahiert Text pro physischer PDF-Seite. Die gespeicherte Seitenzahl
ist einsbasiert. Steuerzeichen werden entfernt, Unicode wird normalisiert,
Zeilenumbrüche bleiben an Absatzgrenzen erhalten. Dokumentinhalt wird nie in
Logs geschrieben.

## Chunking

Standardziel sind ungefähr 900 Unicode-Zeichen mit 150 Zeichen Überlappung:

- jede Seite wird zunächst in Absätze zerlegt;
- kurze Absätze werden bis zum Ziel zusammengeführt;
- lange Absätze werden bevorzugt an Satzgrenzen geteilt;
- ein Chunk gehört immer zu genau einer Seite;
- Tabellenzeilen bleiben soweit anhand wiederkehrender Spaltenabstände
  erkennbar zusammen;
- leere Seiten erzeugen keinen Chunk.

Die Seite ist die harte Grenze. Dadurch ist jede Quelle eindeutig, auch wenn
etwas Kontext verloren geht. Die Chunker-Version ist Teil des Indexstands.

## Transaktion

Ein Dokumentupdate läuft in einer Datenbanktransaktion:

1. neuen Inhaltshash anlegen oder bekannten Inhalt wiederverwenden;
2. Seiten und Chunks erzeugen;
3. FTS-Zeilen aktualisieren;
4. Embeddings batchweise erstellen;
5. neuen Indexstand aktivieren;
6. verwaiste alte Inhalte nach erfolgreicher Standortzuordnung entfernen.

Ein Abbruch vor Schritt 5 lässt die letzte vollständige Version aktiv.
Veraltete Chunks werden erst nach erfolgreicher Aktivierung aus dem aktiven
Suchraum entfernt.

## Embeddingwechsel

Jeder Vektor trägt Modell-ID, Modellversion, Dimension und Normalisierung.
Bei einem Modellwechsel wird ein paralleler Indexstand aufgebaut. Die UI zeigt
Dokument-/Chunk-Fortschritt. Abbruch oder Fehler lassen den vorherigen
Indexstand unverändert.
