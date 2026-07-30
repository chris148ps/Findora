# Lokaler Modellmanager

Der Modellpfad ist unabhängig vom Datenspeicher auswählbar. Modelle,
Tokenizer, Metadaten, Prüfsummen und partielle Downloads liegen gemeinsam im
konfigurierten KI-Modellspeicher. Eine Migration pausiert aktive Nutzung,
kopiert und hasht Dateien und aktiviert den neuen Ort erst nach vollständiger
Validierung. Der Altbestand bleibt bis zur separaten Papierkorb-Bestätigung
bestehen; siehe `STORAGE_ARCHITECTURE.md`.

## Fest eingebauter Katalog

Der Modellkatalog ist als versionierte JSON-Ressource in der App gebündelt.
Es gibt keinen Remote-Katalog, keine konfigurierbare Quelle, keine
Repository-Einstellung und keine automatische Katalogprüfung. Neue Einträge
oder Modellversionen kommen nur mit einem App-Update.

Der Katalog erlaubt ausschließlich gepinnte HTTPS-Dateien auf der internen
Host-Allowlist. Jede Datei enthält erwartete Bytezahl, SHA-256, feste Revision
und relativen Zielpfad. Zusätzlich wird das Manifest selbst gehasht.
Der Katalog ist Bestandteil des signierten App-Bundles und wird daher nicht
als veränderbare Remote-Datei vertraut. Die interne Ad-hoc-Signatur ist keine
Publisher-Vertrauenskette; vor externer Freigabe muss dieselbe Grenze mit
Developer ID, Notarisierung und einem dokumentierten Schlüsselwechselprozess
abgenommen werden. Upstream-Modelldateien besitzen derzeit keine eigene
Publisher-Signatur und werden deshalb ausschließlich über die fest im Bundle
gepinnten SHA-256-Werte akzeptiert.

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

Benötigte empfohlene Modelle können automatisch nach demselben Ablauf geladen
werden, wenn der Nutzer den standardmäßig ausgeschalteten Schalter
**Benötigte empfohlene Modelle automatisch herunterladen** aktiviert hat.
Diese Zustimmung gilt nur für fest gepinnte, kompatible Katalogmodelle.
`ModelRouter` wählt dabei Qwen 3.5 für Extraktion/Antwort und Phi-4 Mini für
die unabhängige Prüfung. Experimentelle Visionmodelle werden dadurch nicht
stillschweigend geladen.

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

Embedding-, Antwort-, Prüf- und Visionmodelle sind getrennte Rollen. Das Antwortmodell wird
erst für eine Antwort geladen und nach Inaktivität, bei Modellwechsel oder
kritischem Speicherdruck entladen. Das Embeddingmodell erzeugt den lokalen
Suchindex; sein Wechsel erfordert deshalb die beschriebene Neuindexierung.

`LocalGenerativeTaskGate` bildet zusätzlich die prozessweite harte
Exklusivgrenze: Vordergrundantworten, Qwen-Extraktion, Phi-Prüfung und
Gemma-/GLM-Vision laufen niemals gleichzeitig. Vor einem Rollenwechsel wird
die vorherige große Laufzeit entladen; kritischer Speicherdruck pausiert neue
Agentenjobs.

Apple Vision OCR ist ein systemeigener `OCRProvider` und benötigt weder
Modellkatalog noch Download. Es bleibt vollständig von Embedding- und
Antwortmodellen getrennt. Weitere OCR-Engines können dieselbe
Provider-Schnittstelle implementieren, ohne Modellverwaltung, Datenbank,
Indexierung oder Suche anzupassen.

## Installiert, aktiviert und geladen

Diese Zustände sind getrennt. `model_states` speichert installierte Version,
Pfad, letzte Integritätsprüfung und genau ein aktiviertes Modell je Rolle.
„Deaktivieren“ löscht keine Modelldateien:

- ohne Embedding-Modell bleibt FTS aktiv, semantische Suche ist aus und
  vorhandene Embeddings bleiben gespeichert;
- ohne Antwortmodell bleiben Suche und regelbasierte Suchplanung aktiv, nur
  die lokale KI-Antwort entfällt.

„Entfernen“ ist eine eigene, bestätigungspflichtige Aktion und verschiebt nur
die Modelldateien in den Papierkorb. Nach einem Neustart werden aktivierte
Modelle aus SQLite wiederhergestellt; der geladene RAM-Zustand entsteht erst
bei tatsächlicher Nutzung.
