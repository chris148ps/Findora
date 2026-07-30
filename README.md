# Findora

Findora ist eine native macOS-App für lokale OCR, Indexierung, semantische
Suche und eine quellengebundene Wissensschicht in privaten PDF- und
E-Mail-Beständen. Dokumente,
E-Mail-Inhalte, Suchanfragen,
Embeddings und Antworten bleiben auf dem Mac. Es werden weder Ollama noch ein
externer KI-Server oder eine Cloud-KI benötigt.

Die technische Identität verwendet durchgängig `Findora`: Bundle-ID
`de.findora.app`, Swift-Module, Build-Targets sowie Daten-, Modell-,
Bookmark- und Logpfade tragen denselben Produktnamen.

## Voraussetzungen

- Apple-Silicon-Mac mit mindestens 8 GB Unified Memory
- macOS 14 oder neuer
- Xcode 26 mit installierter Metal-Toolchain

```bash
xcodebuild -downloadComponent MetalToolchain
```

Apple Vision ist die standardmäßige OCR-Engine und benötigt keine externe
Installation. Nur für ausdrücklich gewähltes Tesseract oder dauerhaft mit
Textschicht versehene PDFs werden OCRmyPDF, Tesseract und Poppler geprüft.
Fehlende Komponenten installiert die App ausschließlich nach ausdrücklicher
Bestätigung; sie verwendet feste Homebrew-Paketnamen und weder Shell noch
`sudo`.

## Build

```bash
swift test
./scripts/build-app.sh
```

MLX enthält Metal-Shader. Deshalb erzeugt `build-app.sh` den produktiven Build
mit Xcode und nicht mit `swift build`. Das Ergebnis liegt unter
`build/Findora.app`.

## Installation

Für die interne, ad-hoc signierte Version:

1. `build/Findora.app` nach `/Applications` kopieren.
2. Die App aus dem Finder öffnen.
3. Falls macOS die interne Signatur beanstandet, im Finder mit Rechtsklick
   **Öffnen** wählen.

Diese interne Version ist nicht notarisiert. Vor einer externen Verteilung
sind Developer-ID-Signierung,
Notarisierung und die Lizenz-/Bundle-Strategie für OCR-Abhängigkeiten separat
abzuschließen.

## Erster Start und Ordnerberechtigung

Unter **Einstellungen** mit **Ordner auswählen** genau den PDF-Stammordner
freigeben. Die Auswahl erfolgt über den macOS-Dateidialog. Findora
speichert ein Security-Scoped Bookmark und stellt die Berechtigung nach einem
Neustart wieder her. Ist ein Volume nicht verbunden oder die Berechtigung
entzogen, wird das sichtbar gemeldet; der Index wird nicht als leer behandelt.

Symlinks, versteckte Dateien, temporäre Download-Dateien und app-eigene
Arbeitsdateien werden nicht verfolgt. Der Ordner wird rekursiv durchsucht.

## OCR

Findora prüft jede PDF mit PDFKit seitenweise. Zeichen-, Wort- und
Plausibilitätswerte sowie die Verfügbarkeit echter PDFKit-Selektionen
entscheiden, ob die native Textschicht brauchbar ist. Nur unbrauchbare,
fehlende oder unvollständige Seiten gehen in die OCR-Pipeline.

Standard ist die nicht-destruktive OCR: Vision liefert den Text ohne
temporäre OCR-PDF direkt an die gemeinsame Qualitäts- und Indexpipeline.
Tesseract verwendet eine temporäre OCR-PDF, die anschließend gelöscht wird.
Text, Seiteninformationen und Qualitätswerte landen in beiden Fällen im
gleichen SQLite-Schema; das Original bleibt unverändert. Optional kann der
Nutzer die validierte OCRmyPDF-Ausgabe atomar am selben Ort übernehmen lassen.
Bei jedem Fehler bleibt das Original unverändert. Ein Modus- oder
Engine-Wechsel verarbeitet bekannte Dokumente nicht automatisch neu.

Unter **OCR** lassen sich Sprachen und konservative Optionen ändern. OCR und
Indexierung können pausiert und fehlgeschlagene Jobs erneut eingeplant werden.

Auch ein formal guter erster OCR-Lauf wird nicht allein wegen Textlänge
übernommen: Die Automatik führt mindestens drei unterschiedliche Versuche aus
und vergleicht Wörter, Artefakte, Fragmentierung und Konfidenz. Insgesamt
probiert die App zentral begrenzt bis zu
acht unterschiedliche Strategien in höchstens 120 Sekunden: Standard,
300 dpi, Kontrast-/Hintergrundkorrektur, Binarisierung,
Begradigung/Randbereinigung, Deutsch + Englisch, eine verfügbare alternative
Engine und zuletzt 400 dpi. Nach jedem Lauf wird dieselbe Qualitätswertung
verwendet; eine spätere schlechtere Variante ersetzt niemals die bisher beste.
Unsichere Seiten erscheinen unter **Dokumentenwartung > OCR prüfen**. Dort
können sie als nicht leer bestätigt, mit manuellen OCR-Einstellungen getestet
oder textlich korrigiert beziehungsweise vollständig erfasst werden.
Die Aktion **Diese Seite löschen** arbeitet ohne vorherige Markierung,
validiert Hash und Seitenzahl, schreibt zunächst eine neue PDF und ersetzt das
Original erst nach erneuter Prüfung. Die geprüfte Originalfassung landet im
macOS-Papierkorb.

## Erstindexierung

Nach der Ordnerauswahl startet ein Vollscan. Danach kombiniert die App
Dateisystemhinweise mit einem periodischen Differenzscan. Der persistente
Jobstatus erlaubt die Fortsetzung nach einem Neustart.

Status, Warteschlange und technische Fehler erscheinen unter **Status** und
**Logs**. Inhalte von Dokumenten werden nicht protokolliert.
Das dauerhaft lesbare technische Protokoll liegt unter
`~/Library/Logs/Findora/Findora.log`.

Automatische Crashberichte sind standardmäßig aktiviert und können unter
**Einstellungen → Crashberichte** jederzeit deaktiviert werden. Sie werden
über die lokal konfigurierte Apple-Mail-App an den fest konfigurierten
Findora-Support gesendet. Vor dem Versand werden E-Mail-Adressen und private
Pfade geschwärzt; Dokumentinhalte, Suchanfragen, OCR-Texte, Dateinamen und
Antworten werden nicht aufgenommen. Details:
[`CRASH_REPORTING.md`](CRASH_REPORTING.md).

Der Dokumentenstatus aktualisiert sich während Scan, OCR, Indexierung,
Embedding-Erstellung und Wartung automatisch. Datenbankereignisse werden
gebündelt innerhalb von etwa 300 ms dargestellt; ein manueller Ansichtswechsel
oder Neuladen ist nicht erforderlich.

Die normale Ansicht zeigt bewusst nur **PDFs insgesamt**, **Indexiert**,
**In Warteschlange** und **Duplikate**. OCR-, Embedding-, Fehler- und
Qualitätswerte stehen weiterhin im standardmäßig eingeklappten Bereich
**Technische Details** zur Verfügung.

Die technischen Zähler sind nach Dokumenten, Texterkennung, Suche/Index und
Wartung gruppiert. Dokument- und Seitenwerte sind ausdrücklich gekennzeichnet;
exklusive Indexklassen, mathematische Beziehungen, Resetverhalten und die
Diagnose **Statuswerte prüfen** beschreibt
[`DOCUMENT_STATUS.md`](DOCUMENT_STATUS.md).

## E-Mail-Quellen

Unter **E-Mail-Quellen** oder im Menü **Ablage** lassen sich Apple-Mail-MBOX,
EML, Outlook-MSG und rekursive Importordner manuell auswählen. Findora greift
beim Start nicht auf Mail oder Outlook zu und zeigt kein Mail-Onboarding.
Vor dem Import werden Umfang und Speicherbedarf zusammengefasst; die Quelle
kann referenziert oder zusätzlich verifiziert archiviert werden.
Ordnerüberwachung ist standardmäßig aus. Details:
[`MAIL_IMPORT.md`](MAIL_IMPORT.md).

## Datenspeicher und Modellspeicher

Unter **Einstellungen → Speicher** können Datenbank/Mailarchive und
KI-Modelle unabhängig verschoben werden. Findora kopiert zunächst, validiert
Größen und SHA-256, prüft SQLite und schaltet erst danach um. Der Altbestand
bleibt bis zu einer eigenen Papierkorb-Bestätigung erhalten. Ein fehlendes
externes Datenvolume erzeugt niemals automatisch eine leere Ersatzdatenbank.
Details: [`STORAGE_ARCHITECTURE.md`](STORAGE_ARCHITECTURE.md).

## Modellauswahl

Unter **Modelle** stehen nur fest versionierte, lizenzierte MLX-Modelle aus dem
eingebauten Katalog. Vor der Installation zeigt die App Lizenz,
Downloadgröße und RAM-Einstufung. Jede Datei wird per SHA-256 validiert.

- Embeddings: multilingual E5 Small, 384 Dimensionen
- primäre Wissensextraktion und Antworten: Qwen 3.5 4B 4 Bit
- strukturierte Zweitprüfung: Phi-4 Mini Instruct 4 Bit
- experimentelle visuelle Prüfung: Gemma 4 E2B Instruct 4 Bit
- bestehende Qwen-3-Modelle bleiben als kompatible Altmodelle erhalten
- Qwen3 8B 4 Bit auf 8-GB-Macs nur experimentell
- bestehende optische Alternative: GLM-OCR 4 Bit, Revision
  `97f587506984cc92fa69b2694b4128e53db6b081`, MIT, rund 1,25 GB Download

Downloads lassen sich pausieren, fortsetzen und abbrechen. Ein
Embedding-Modellwechsel erfordert eine Neuindexierung. Das Sprachmodell wird
erst für eine Antwort geladen und bei Speicherdruck oder nach Inaktivität
entladen.
Gemma oder die bestehende GLM-OCR-Alternative werden nur nach ausdrücklichem
Download und nur für ungelöste Seiten verwendet. Unsichere Ergebnisse bleiben
in **OCR prüfen**; das Modell darf weder PDFs ändern noch Seiten löschen oder
manuelle Bewertungen überschreiben.

Capability-Routing, Speicherbudget und exklusive Modell-Leases verhindern auf
8-GB-Geräten unkontrolliertes paralleles Laden großer generativer Modelle.
Automatische empfohlene Downloads sind standardmäßig aus. Details:
[`MODEL_ROUTING.md`](docs/MODEL_ROUTING.md) und
[`MODEL_LICENSES.md`](docs/MODEL_LICENSES.md).

## Lokale Wissensdatenbank

Über Dokument-, Seiten-, OCR-, FTS- und Embeddingdaten liegt eine getrennte
SQLite-Wissensschicht für Entitäten, belegte Fakten, Beziehungen,
Projektkandidaten, Konflikte, Kommunikation und Erfahrungswissen. Sie ersetzt
den klassischen Index nicht.

Modellausgaben werden als versioniertes JSON gegen Schema, Dokument, Seite,
Chunk, wörtliche Textstelle und Confidence geprüft und erst danach vollständig
in einer Transaktion gespeichert. Freie Modelltexte besitzen keinen
Datenbankzugriff. `model_inference` bleibt unsicher und darf weder als
gesicherter Fakt noch als automatische Projektverknüpfung dienen.

Neue oder geänderte Dokumente erhalten idempotente Wissensjobs. Beim Entfernen
werden Belege zunächst als fehlend markiert; ein Fakt bleibt aktiv, solange
ein anderer gültiger Beleg existiert. Die Wissensfunktion ist deaktivierbar;
die klassische Suche funktioniert ohne Wissensmodelle.

Ein lokaler Agentendienst arbeitet diese abhängige Jobkette produktiv ab.
Qwen 3.5 erzeugt das vollständige strukturierte Extraktionsobjekt; bei
Unsicherheit prüft Phi-4 Mini dieselben Originalbelege unabhängig. Qwen wird
vor der Phi-Prüfung entladen. Vordergrundantworten, Extraktion, Prüfung und
optische Analyse teilen zusätzlich eine prozessweite Exklusivsperre, damit auf
8-GB-Systemen niemals zwei große generative Laufzeiten gleichzeitig arbeiten.

Folgeagenten bilden nur aus validiertem Datenbankzustand Konflikte,
Kommunikationsereignisse, starke Projektzuordnungen, beleggebundene
Zusammenfassungen und vorgeschlagene Erfahrungsmuster. Agentenläufe und
technische Zustandsänderungen werden ohne Dokumentinhalt auditiert.
Ontologietypen sind lokal registrierbar und benötigen keine weitere
Schema-Migration.

Unter **Einstellungen → Entwicklung / Diagnose** sind nach Aktivierung des
Entwicklermodus Entitäten, Aussagen, Projektkandidaten,
Kommunikations-Threads, Erfahrungswissen und Wartung sichtbar. Der
Wissensreset verlangt `RESET KNOWLEDGE` und lässt Originaldateien, OCR und
klassischen Suchindex unangetastet. Details:
[`KNOWLEDGE_ARCHITECTURE.md`](docs/KNOWLEDGE_ARCHITECTURE.md) und
[`KNOWLEDGE_VALIDATION.md`](docs/KNOWLEDGE_VALIDATION.md).

Antwort und Quellenliste besitzen einen persistenten nativen macOS-Trenner.
Ein Doppelklick stellt die Standardaufteilung wieder her; kleine Fenster
verwenden eine robuste Antwort-/Quellenwahl.

## Suche und Quellen

Natürliche Anfragen werden zuerst in einen strikt validierten lokalen Suchplan
übersetzt. Regeln sichern Namen, Nummern, Daten und Beträge als
Pflichtbedingungen; bei komplexen Anfragen ergänzt das lokale Antwortmodell
Themen und Synonyme. Ungültiger Modelloutput fällt auf den sicheren
regelbasierten Plan zurück und wird nie als SQL ausgeführt.

Die Suche kombiniert aktive belegte Wissensclaims, SQLite FTS5 und lokale
Vektorsuche über PDFs, E-Mails und indexierbare Anhänge, prüft
Pflichtbedingungen und bewertet Person-/Themennähe erneut. Nur „Sehr passend“
und „Passend“ erscheinen regulär. Unsichere Treffer bleiben getrennt und
eingeklappt. Trefferkarten zeigen Dateiname, Pfad, Seite, hervorgehobenen
Auszug, Relevanz, belegte Person und Thema, OCR-Qualität, Suchart und eine
regelbasierte Begründung.
PDF-Treffer öffnen direkt auf der gespeicherten Seite. PDFKit markiert
native Fundstellen über Selektionen; Apple-Vision-Fundstellen verwenden
temporäre Bounding-Box-Overlays. Fehlen Positionsdaten, bleibt die
seitenrichtige Anzeige erhalten und wird als solche gekennzeichnet.

Für eine formulierte Antwort werden nur die besten lokalen Fundstellen an das
lokale Modell übergeben. Quellen-IDs werden von der App erzeugt und nachher
gegen die Datenbank validiert. Fehlen ausreichende Belege, gibt die App keine
scheinbar belegte Antwort aus.

Die Antwortansicht kennzeichnet das Ergebnis als **Gesichert**, **Berechnet**,
**Wahrscheinlichkeit**, **Erfahrung**, **Konflikt** oder **Unbekannt**. Ohne
gültige Quellen-ID und lokale Originalquelle lautet die Klasse immer
**Unbekannt**.

Der Inhaltstyp lässt sich mit **Alle / Dokumente / E-Mails / Anhänge**
filtern. Die Suchansicht zeigt Nutzerfrage und Markdown-Antwort chatähnlich in einem
präsenten, während der Trefferansicht sichtbaren Bereich. Quellenlinks öffnen
die richtige PDF-Seite. Folgefragen verwenden nur einen auf sechs Schritte
begrenzten Sitzungskontext; ein dauerhaftes Chatgedächtnis gibt es nicht.

## Dokumentenwartung

Unter **Dokumentenwartung** werden SHA-256-Duplikate, leere Seiten,
vollständig leere PDFs, fehlende Dateien sowie Index- und
Embedding-Werkzeuge getrennt verwaltet. Die visuelle Leerseitenanalyse läuft
bei der normalen Dokumentenverarbeitung mit. Für ältere Indexeinträge kann sie
gezielt ergänzt werden, ohne eine zweite OCR zu starten.

Eine Seite gilt nie allein wegen fehlenden OCR-Texts als leer. Die davon
unabhängige visuelle Prüfung berücksichtigt Rendering, Weiß- und Dunkelanteil,
Varianz, Kanten, Kontrastinseln, zusammenhängende Strukturen, Randzonen,
Text-/Bild-/Grafikobjekte und Annotationen. Schon ein relevantes Gegenmerkmal
verhindert **Sicher leer**. Bildseiten, Barcodes, QR-Codes, Formularfelder,
Stempel, Unterschriften, kontrastarme Inhalte und kleine Randnotizen werden
deshalb als Inhalt oder als manuell zu prüfen eingestuft.

Automatische Leereinstufungen sind keine Löschfreigabe. Nur ausdrücklich
manuell als leer bestätigte Seiten sind auswählbar; auch eine ganze leere PDF
erscheint erst nach Bestätigung jeder Seite als Papierkorb-Kandidat.

Dateien werden ausschließlich nach ausdrücklicher Auswahl und Bestätigung
verändert. Duplikate müssen denselben SHA-256 des Originaldokuments besitzen.
Löschaktionen verwenden ausschließlich den macOS-Papierkorb. Beim Entfernen
einzelner Seiten wird zuerst eine neue PDF erzeugt und vollständig validiert;
erst danach folgt ein atomarer Austausch. Die ursprüngliche Fassung landet
zur Wiederherstellung im Papierkorb. Details stehen in
[`MAINTENANCE.md`](MAINTENANCE.md).

## Updates

Version 1 enthält keinen automatischen App- oder Online-Katalog-Updater.
App-Updates werden als vollständig neuer, signierter Build installiert.
Modellupdates sind ausschließlich über den Katalog einer neueren App-Version
möglich. Die neue Version wird vollständig heruntergeladen, größen- und
SHA-256-geprüft und erst danach aktiviert. Bei einem Fehler bleibt die alte
Version erhalten. Für Embedding-Updates wird der Index aus dem gespeicherten
Seitentext neu aufgebaut; Antwortmodell-Updates benötigen keine
Neuindexierung.

## Oberfläche, Sprache und Erscheinungsbild

Unter **Einstellungen → Darstellung** stehen Deutsch, Englisch und die
unterstützte Systemsprache sowie System, Hell und Dunkel zur Auswahl. Beide
Entscheidungen werden in SQLite gespeichert und auf Hauptfenster,
Menüleistenfenster und Einstellungen angewendet. Deutsch bleibt für bestehende
Installationen ohne gespeicherte Wahl der Standard.

Die Fortschrittsanzeige wird aus einer persistenten Verarbeitungssitzung
gespeist. Sie bleibt deshalb zwischen Scan, OCR und Indexierung stabil,
überlebt einen App-Neustart und zeigt den Abschluss noch kurz an.

## Fehlerbehebung

Die wichtigsten Prüfungen:

```bash
ocrmypdf --version
tesseract --list-langs
pdftotext -v
pdfinfo -v
xcodebuild -showComponent MetalToolchain -json
```

Die externen Prüfkommandos sind nur für Tesseract/OCRmyPDF relevant. Bei
fehlender Ordnerberechtigung den Stammordner erneut auswählen. Bei fehlenden
OCR-Sprachen `tesseract-lang` installieren. Weitere Fälle stehen in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Deinstallation

1. Findora beenden.
2. Optional den Login-Start in **Einstellungen** vorher deaktivieren.
3. `Findora.app` löschen.
4. Nur wenn Index, Modelle und Einstellungen ebenfalls entfernt werden
   sollen:

```text
~/Library/Application Support/Findora/
~/Library/Logs/Findora/
```

Private PDFs liegen außerhalb dieser Pfade und werden bei der Deinstallation
nicht gelöscht.

## Projektunterlagen

- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`OCR_PIPELINE.md`](OCR_PIPELINE.md)
- [`DOCUMENT_STATUS.md`](DOCUMENT_STATUS.md)
- [`INDEXING_PIPELINE.md`](INDEXING_PIPELINE.md)
- [`SEARCH_PIPELINE.md`](SEARCH_PIPELINE.md)
- [`MAINTENANCE.md`](MAINTENANCE.md)
- [`MODEL_MANAGER.md`](MODEL_MANAGER.md)
- [`PRIVACY.md`](PRIVACY.md)
- [`SECURITY.md`](SECURITY.md)
- [`TESTING.md`](TESTING.md)
- [`UI_LOCALIZATION.md`](UI_LOCALIZATION.md)
- [`FINDORA_UI.md`](FINDORA_UI.md)
- [`docs/CODEX_WORKFLOW.md`](docs/CODEX_WORKFLOW.md)
- [`docs/AGENT_SYSTEM.md`](docs/AGENT_SYSTEM.md)
- [`docs/LOCAL_API.md`](docs/LOCAL_API.md)
- [`docs/DEVELOPER_GUIDE.md`](docs/DEVELOPER_GUIDE.md)
