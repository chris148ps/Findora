# Lokaler Modellmanager

## Fest eingebauter Katalog

Der Modellkatalog ist als versionierte JSON-Ressource in der App gebündelt.
Es gibt keinen Remote-Katalog, keine konfigurierbare Quelle, keine
Repository-Einstellung und keine automatische Katalogprüfung. Neue Einträge
oder Modellversionen kommen nur mit einem App-Update.

Der Katalog erlaubt ausschließlich gepinnte HTTPS-Dateien auf der internen
Host-Allowlist. Jede Datei enthält erwartete Bytezahl, SHA-256, feste Revision
und relativen Zielpfad. Zusätzlich wird das Manifest selbst gehasht.

## Download, Installation und Update

Downloads zeigen Fortschritt und unterstützen Pausieren, Fortsetzen und
Abbrechen. Der sichere Ablauf ist:

1. Kompatibilität und freien Speicher prüfen;
2. Lizenz, Downloadgröße, RAM-Einstufung, Version und Prüfsumme anzeigen;
3. in ein versionsspezifisches Staging-Verzeichnis laden;
4. Bytezahl und SHA-256 jeder Datei prüfen;
5. das Modell lokal laden und funktional testen;
6. die vollständig geprüfte Version in `Models/<id>/<version>` verschieben;
7. erst danach aktivieren.

Erkennt der Katalog einer neueren App eine Version über einer bereits
installierten, zeigt die Oberfläche „Modell aktualisieren“. Bei Download-,
Prüfsummen- oder Laufzeittestfehler bleibt die ältere Version erhalten.

Embedding-Updates bauen Chunks, FTS und Embeddings transaktional aus dem
gespeicherten Seitentext neu auf. Antwortmodell-Updates benötigen keinen
Dokument-Reindex.

## Kompatibilität

Katalog und Laufzeit berücksichtigen Apple Silicon, physischen RAM, freien
SSD-Speicher, Weight-Größe, Quantisierung, Kontext/KV-Cache und eine
2,5-GB-Systemreserve. Die vier Statuswerte sind:

- empfohlen;
- kompatibel;
- experimentell;
- nicht kompatibel.

Nicht kompatible Modelle können nicht installiert werden. Experimentelle
Modelle werden nur angezeigt, wenn der Benutzer sie ausdrücklich einblendet.
Qwen 3 8B 4 Bit ist auf einem 8-GB-Mac experimentell.

## Lifecycle

Embedding- und Antwortmodelle sind getrennte Rollen. Das Antwortmodell wird
erst für eine Antwort geladen und nach Inaktivität, bei Modellwechsel oder
kritischem Speicherdruck entladen. Das Embeddingmodell erzeugt den lokalen
Suchindex; sein Wechsel erfordert deshalb die beschriebene Neuindexierung.

Apple Vision OCR ist ein systemeigener `OCRProvider` und benötigt weder
Modellkatalog noch Download. Es bleibt vollständig von Embedding- und
Antwortmodellen getrennt. Weitere OCR-Engines können dieselbe
Provider-Schnittstelle implementieren, ohne Modellverwaltung, Datenbank,
Indexierung oder Suche anzupassen.
