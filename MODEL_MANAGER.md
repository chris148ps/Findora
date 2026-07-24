# Modellmanager

## Vertrauensmodell

Der mit der App ausgelieferte Katalog ist signierter bzw. im App-Build
versionierter Code-Input. Nur HTTPS-Hosts auf einer Allowlist und im Katalog
vollständig definierte Dateien dürfen geladen werden. Weiterleitungen auf
nicht erlaubte Hosts werden abgewiesen.

Jede Modelldatei besitzt:

- erwartete Bytezahl;
- SHA-256;
- feste Modellrevision;
- lokale relative Zieladresse.

Eine Prüfsumme über nur ein Manifest reicht nicht. Ein Modell wird erst nach
Validierung aller Dateien installiert.

## Download und Installation

Downloads verwenden `URLSessionDownloadTask` mit sichtbarem Fortschritt und
Resume-Daten. Der Ablauf ist:

1. Kompatibilität und freien Speicher prüfen;
2. Lizenz anzeigen und Zustimmung speichern;
3. in `.downloads/<UUID>` herunterladen;
4. jede Datei hashen;
5. Modell lokal in einem isolierten Laufzeittest laden;
6. Verzeichnis atomar nach `Models/<id>/<version>` verschieben;
7. Version als installiert markieren.

Bei Update bleibt die aktive alte Version erhalten, bis Schritt 5 für die neue
Version erfolgreich war. Abbruch löscht keine installierte Version.

## Kompatibilität

Katalog und Laufzeitprüfung berücksichtigen:

- Apple Silicon;
- physischer RAM;
- aktuellen Speicherdruck;
- verfügbaren SSD-Speicher;
- Weight-Größe und Quantisierung;
- Kontext und KV-Cache;
- Laufzeit-/Promptbuffer;
- gleichzeitig benötigte Komponenten;
- 2,5-GB-Systemreserve auf einem 8-GB-Mac.

Statuswerte:

- empfohlen;
- kompatibel;
- experimentell;
- nicht kompatibel.

Nicht kompatible Modelle können nicht aktiviert werden. Experimentelle Modelle
werden nur nach zwei ausdrücklichen Nutzeraktionen installiert/aktiviert.

## Lifecycle

Das aktive Modell ist eine Einstellung, kein dauerhaft geladener Prozess.
Bei einer Frage:

1. Speicherbudget erneut prüfen;
2. OCR bei Bedarf pausieren;
3. Modell laden;
4. Antwort streamen;
5. Aktivitätstimer neu starten;
6. nach Standard zehn Minuten entladen.

Kritischer Speicherdruck oder Modellwechsel bricht eine laufende Antwort
kontrolliert ab und gibt den Container frei. Der Embedder wird getrennt
verwaltet.

## Katalogpflege

Ein späterer Online-Katalog wird nur nach Signaturprüfung übernommen. Die
eingebaute Version bleibt als Fallback verfügbar. Beliebige URLs aus
Nutzereingaben sind nicht vorgesehen.

Modelllizenzen werden unabhängig von Backendlizenzen geprüft. Der initiale
Katalog verwendet nur Modelle mit klarer, redistributionsfähiger Lizenz.

