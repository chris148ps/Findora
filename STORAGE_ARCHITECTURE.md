# Speicherarchitektur und sichere Migration

Findora behandelt zwei unabhängig konfigurierbare Speicher:

- **Findora-Datenspeicher:** SQLite/FTS, Chunks, Embeddings, OCR- und
  Mailtexte, Beziehungen, Wartungsdaten und optionale Mailarchive.
- **KI-Modellspeicher:** installierte Modelle, Metadaten, Prüfsummen und
  partielle Downloads.

Standard sind `~/Library/Application Support/Findora` und dessen Unterordner
`Models`. Benutzergewählte Ziele erhalten Security-Scoped Bookmarks.

## Zielprüfung

Vor einer Migration ermittelt Findora Dateizahl, Datenmenge, freien Speicher,
lokale/readonly-Eigenschaften und die von macOS gemeldete
Dateisystembeschreibung. Netzwerkziele, schreibgeschützte Volumes,
Cloud-Synchronisationspfade sowie bekannte FAT-, ExFAT-, NTFS-, SMB-, NFS-
und WebDAV-Ziele werden gesperrt. APFS wird bevorzugt, Mac OS Extended
akzeptiert. Eine unbekannte Beschreibung erzeugt eine Warnung.

## Ablauf

1. Neue Suche, OCR, Indexierung, Downloads und Mailimporte werden blockiert.
2. Tasks und Ordnerbeobachter werden beendet oder pausiert.
3. Beim Datenspeicher wird SQLite per WAL-Checkpoint vollständig geschlossen.
4. Die Quelle wird ohne Symlinks und getrennten Modellspeicher inventarisiert.
5. Dateien werden in einen eindeutigen Staging-Ordner kopiert.
6. Größe und SHA-256 jeder Datei werden gegen die Quelle geprüft.
7. Die kopierte Datenbank muss `PRAGMA quick_check = ok` liefern.
8. Erst dann wird Staging atomar zu `FindoraData` oder `FindoraModels`
   umbenannt und das Bookmark gespeichert.
9. Datenbank, Index-, Modell- und Maildienste werden am neuen Ort neu geladen.

Der Altbestand bleibt erhalten. Nur ein separater, bestätigter Befehl
verschiebt ihn später in den macOS-Papierkorb.

## Unterbrechung und fehlendes Volume

Der persistente Zustand kennt Vorbereitung, Kopieren, Validieren, Umschalten,
Abgeschlossen, Fehlgeschlagen und Rückfall erforderlich. Die UI bietet
Fortsetzen, Rückkehr zum alten Speicher und Verwerfen eines fehlgeschlagenen
Staging-Bestands.

Fehlt ein konfigurierter externer Datenspeicher beim Start, legt Findora dort
keinen Ordner und keine leere Datenbank an. Stattdessen zeigt die App den
erwarteten Pfad und ermöglicht erneutes Prüfen oder die bewusste Zuordnung
eines vorhandenen Findora-Datenspeichers.

