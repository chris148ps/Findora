# Datenschutz

Stand: 24. Juli 2026

Findora ist als lokale Einzelbenutzer-Anwendung entworfen.

## Was lokal bleibt

- ausgewählte PDFs und extrahierter Text;
- manuell ausgewählte Mailarchive, Mailmetadaten, normalisierter Mailtext und
  indexierte Anhänge;
- Suchanfragen und Suchverlauf;
- Volltextindex und Embeddings;
- Kommunikationspartner, Organisationen, Projekte, Beziehungen und
  dokumentbezogene Analyseversionen;
- an das lokale Sprachmodell übergebene Auszüge;
- erzeugte Antworten;
- Einstellungen, Jobstatus und technische Logs.

Es erfolgt keine Übertragung von Dokument-, E-Mail- oder Anhangsinhalten,
Kommunikationsbeziehungen, Suchanfragen oder Antworten an OpenAI oder andere
KI-Anbieter. Es gibt
standardmäßig keine Telemetrie,
Analyse-, Crash-Upload- oder Tracking-Funktion.

Suchpläne und Folgefragen werden nur im Arbeitsspeicher der laufenden Sitzung
gehalten. Der Chatverlauf ist auf sechs Schritte begrenzt, wird nicht
persistiert und nicht automatisch exportiert.

## Netzwerkzugriff

Netzwerkzugriff wird nur für eine vom Nutzer gestartete Modellinstallation
verwendet. Dateien werden ausschließlich von den im eingebauten Modellkatalog
festgelegten HTTPS-Quellen und Revisionen geladen. Vor der Aktivierung werden
Größe und SHA-256 jeder Datei geprüft.

Der Modellhost kann beim Download technisch übliche Metadaten wie IP-Adresse,
Zeitpunkt, User-Agent und angeforderte Modellpfade sehen. PDF-Inhalte oder
Suchanfragen werden dabei nicht übertragen.

## Lokale Speicherung

```text
~/Library/Application Support/Findora/
~/Library/Logs/Findora/
```

Der Datenspeicher und der davon getrennte Modellspeicher können nach
ausdrücklicher Auswahl auf ein geeignetes lokales Volume verschoben werden.
Security-Scoped Bookmarks und letzte Pfade bleiben lokal.
Mail-Ordnerüberwachung ist standardmäßig deaktiviert.

Logs enthalten keine extrahierten Dokumenttexte, Suchauszüge, Prompts oder
Antworten. Sie enthalten auch keine Suchanfragen, erkannten Personen,
Vertragsdaten oder Suchpläne. Sie dürfen Dateiname, Pfad, Status und technische
Fehlermeldungen enthalten. Pfade können private Informationen verraten;
Logdateien sollten daher wie andere lokale Anwendungsdaten behandelt werden.

Leerseitenmetriken und manuelle Prüfentscheidungen werden ausschließlich in
der lokalen SQLite-Datenbank gespeichert. Vorschaubilder werden bei Bedarf aus
der lokalen PDF erzeugt und nicht exportiert.

## Löschen

Index, Modelle, Einstellungen und Logs können durch Löschen der oben genannten
App-Verzeichnisse entfernt werden. Die privaten Original-PDFs werden dadurch
nicht verändert oder gelöscht.

Dokumentenwartung löscht keine Datei endgültig. Ausdrücklich bestätigte
Dateiaktionen verwenden den macOS-Papierkorb. Beim Entfernen einzelner Seiten
wird auch die vorherige vollständige PDF-Fassung in den Papierkorb verschoben,
damit sie wiederherstellbar bleibt.
