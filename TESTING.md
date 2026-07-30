# Teststrategie

## Schneller Testlauf

```bash
swift test
./scripts/check-product-name.sh
./scripts/check-retired-features.sh
```

Die automatisierten Tests verwenden ausschließlich künstlich erzeugte
Textdateien, PDFs, EML/MBOX/MSG-Container und temporäre SQLite-Datenbanken.
Private Dokumente oder Mailarchive sind nicht erforderlich.

Abgedeckt sind:

- rekursiver Scan, Ausschlüsse und Symlink-Verhalten;
- temporäre OCR-Namen;
- Seitenextraktion und seitengebundenes Chunking;
- deterministischer Fallback-Embedder;
- regelbasierte Suchplanung für Pflichtentität, Thema und UND-Verknüpfung;
- strikte Modellplanvalidierung einschließlich Fallback und SQL-Abweisung;
- Pflichtfilter für Name in digitalem Text, OCR-Text und Dateiname;
- Re-Ranking für selben Chunk und getrennte Chunks desselben Dokuments;
- Ausschluss von Dokumenten ohne Pflichtperson oder Themenbeleg ohne
  künstliches Auffüllen;
- Quellen-ID-Validierung und begrenzter Sitzungskontext;
- Erkennung eines gemischten E5-/Fallback-Embeddingindex;
- SQLite-Migration, Indexierung, hybride Suche, Umbenennen, Verschieben,
  identische Kopie, Metadatenänderung, Inhaltsänderung und Löschen;
- unverändertes Original bei korrupter OCR-Eingabe;
- reale OCRmyPDF-Verarbeitung einer synthetischen Scan-PDF im
  nicht-destruktiven und persistenten Modus;
- reale Apple-Vision-OCR einer synthetischen Scan-PDF ohne Originaländerung;
- Automatikmodus ohne Tesseract, Vision-zu-Tesseract-Fallback und erzwungenes
  OCRmyPDF im dauerhaften Modus;
- identische Suchresultate und Datenbankaggregation für beide OCR-Provider;
- Moduswechsel ohne automatische Neuverarbeitung;
- Finder-sichere Toolauflösung und sicherer Abbruch ohne Homebrew;
- seitenweise OCR-Qualität einschließlich Tesseract-Konfidenz;
- Erkennung einer älteren installierten Modellversion;
- ereignisgetriebener Dokumentenstatus unter 500 ms;
- konsistente OCR-/Job-/Chunk-/Embedding-/Duplikatzähler;
- exklusive Dokumentklassen für digitale, reine OCR-, gemischte und textlose
  synthetische PDFs sowie getrennte PDF-/OCR-/Leerseitenzähler;
- mathematische Statusdiagnose, Duplikatentfernung, wiederholten Scan und
  identische Rekonstruktion nach Datenbank-Neustart;
- persistierte Pause und identische Statusrekonstruktion nach Datenbank-Neustart;
- genau vier primäre Dokumentenstatus-Kennzahlen;
- visuelle Leerseitenerkennung für vollständig leere Seiten, Trennseiten,
  Bildseiten, Unterschriften, Stempel, Barcode, QR-Code, Formularfeld,
  Annotation, kontrastarme Seiten, extrem hohen Weißanteil und kleine
  Randnotizen;
- eindeutige, begrenzte OCR-Strategiefolge, progressive Verbesserung,
  Bestvariantenauswahl, Schutz gegen spätere Verschlechterung, Versuchslimit
  und kontrollierten Abbruch;
- Schutz manueller Nichtleer-Entscheidungen bei erneuter Analyse und
  Zurücksetzen bei geändertem SHA-256;
- gezielte FTS-/Chunk-/Embedding-Aktualisierung für korrigierten Seitentext,
  Bewahrung der ursprünglichen OCR-Fassung und unverändertes Original;
- getrennte Erkennung vollständig leerer und gemischter PDFs;
- bestätigte Einzelseitenentfernung mit PDF-, Reihenfolge- und
  Reindexierungsprüfung;
- SHA-256-Duplikate über verschiedene Namen und Speicherorte sowie Ausschluss
  gleichnamiger Dateien mit anderem Inhalt;
- Papierkorb- und Datenbankaktualisierung einschließlich vollständigem
  Rollback bei einem simulierten Mehrdateifehler;
- Vollständigkeit, Revisionen und Hashes des Modellkatalogs;
- Hardware-Einstufung des Katalogs.
- MIME/RFC-2047/HTML-Normalisierung und Anhangsdekodierung;
- gestreamte MBOX und synthetischer Unicode-Outlook-MSG-Container;
- Mail-/Anhangsdeduplizierung und PDF/E-Mail/Anhang-Suchfilter;
- Mail zuerst/PDF später und PDF zuerst/Mail später;
- identischer PDF-Anhang per SHA-256 sowie gleicher Dateiname mit
  abweichendem Inhalt nur als Vorschlag;
- direkte lokale Mail-/Dokumentverknüpfungen bei identischem Anhang sowie
  der Ausschluss von Partner-/Projektprofilen aus Import und Suche;
- Upgrade von Schema 10 und 11 ohne Verlust von Dokumenten, OCR, Mail oder
  Embeddings;
- transaktionaler Rollback und Fortsetzung nach unterbrochener Migration;
- pausierbare inkrementelle Analyse-Upgrades sowie `quick_check` und
  `integrity_check`;
- sichere Speicherkopie, Hash-/SQLite-Prüfung, Umschaltung und Altbestand;
- Richtlinien für im führenden Dokumentenordner entfernte PDFs.
- produktive Abarbeitung aller elf abhängigen Wissensjobstufen mit
  schema-validierter Modellantwort, Agentenläufen und Auditereignissen;
- `waiting_for_model` und Wiederaufnahme nach Modellaktivierung;
- erweiterbare, lokal registrierte Ontologietypen ohne weitere
  Schema-Migration;
- fail-closed Antwortklassen sowie Berechnet- und Konfliktklassifikation;
- exklusive prozessweite Generativsperre zusätzlich zu Modellleases;
- Verwerfen von `model_inference` als dauerhaftem Fakt, Erzeugen und späteres
  Schließen der zugehörigen Wissenslücke;
- Schema 16 mit Agenten-, Audit-, Ontologie- und Projektquellenfeldern.

## Reale MLX-Integration

Die MLX-Integration benötigt die Xcode-Metal-Toolchain und muss über Xcode
gebaut werden:

```bash
xcodebuild -downloadComponent MetalToolchain
./scripts/test-mlx.sh
```

Der Opt-in-Test lädt das fest gepinnte E5-Modell in ein temporäres Verzeichnis,
prüft alle Hashes, lädt es mit MLX und erzeugt normalisierte
384-dimensionale Embeddings. Das temporäre Modell wird nach dem Test entfernt.
Der Test ist opt-in, weil er rund 252 MB Netzwerktransfer benötigt.

Der getrennte Antwortmodelltest lädt rund 984 MB, prüft alle Dateien und
erzeugt mit Qwen3 1.7B 4 Bit eine kurze Antwort:

```bash
./scripts/test-llm.sh
```

Die statischen SwiftUI-Schlüssel und die englische Ressource werden zusätzlich
geprüft mit:

```bash
./scripts/check-localization.sh
```

## App-Build prüfen

```bash
./scripts/build-app.sh
codesign --verify --deep --strict build/Findora.app
```

Danach manuell:

1. App auf Apple Silicon starten.
2. Einen ausschließlich synthetischen Testordner wählen.
3. App neu starten und Bookmark-Wiederherstellung prüfen.
4. Text-PDF, Scan-PDF, gemischte PDF und beschädigte PDF hinzufügen.
5. Während eines Kopiervorgangs Stabilitätsprüfung beobachten.
6. OCR pausieren, fortsetzen und App während eines Jobs neu starten.
7. Umbenennen, Verschieben, Ändern und Löschen erkennen lassen.
8. Identische Kopie und reine Zeitstempeländerung ohne Neuindexierung prüfen.
9. Beide OCR-Modi und einen Moduswechsel prüfen.
10. E5 und ein kompatibles Antwortmodell installieren.
11. Volltext-, semantische und gemischte Fragen prüfen.
12. Quellen gegen PDF-Seiten verifizieren.
13. Antwort abbrechen und Entladen bei Speicherdruck/Inaktivität prüfen.
14. Volume aushängen; der Index darf nicht als leer behandelt werden.
15. Dokumentenstatus auf vier Hauptkennzahlen und eingeklappte technische
    Details prüfen.
16. Wartungslisten durchsuchen, sortieren, Seiten vorschauen und Entscheidungen
    zurücksetzen.
17. Nur mit synthetischen PDFs Papierkorb- und Seitenaustauschdialoge prüfen.
18. **OCR prüfen** mit Mehrfachauswahl, automatischer Nachbearbeitung und
    sichtbarer Strategie-/Qualitätsanzeige prüfen.
19. Manuelle OCR mit Vision/Tesseract, Sprache, Drehung und 300/400/600 dpi
    testen; 600-dpi-Warnung und Einzelverarbeitung beobachten.
20. OCR-Text korrigieren und vollständig manuell erfassen; FTS-Suche,
    Seitenchunks, Embeddings, Original-OCR-Rücksetzung und unveränderten
    PDF-Hash prüfen.
21. Alle drei Reset-Arten mit synthetischen PDFs prüfen; insbesondere
    manuelle Texte/Entscheidungen beim automatischen Reset und vollständige
    leere Wartungslisten beim Vollreset.
22. In jeder Wartungsliste Alle, Keine und Auswahl umkehren mit aktivem Filter
    prüfen; bei Duplikaten muss je Gruppe ein Speicherort erhalten bleiben.
23. Erwartete interne und bewusste Abbrüche auslösen; es darf kein Dialog mit
    rohem `CancellationError` erscheinen.
24. Antwort- und Embedding-Modell getrennt deaktivieren, App neu starten und
    FTS-Suche sowie persistierte Modellzustände prüfen.
25. Deutsch, Englisch, Systemsprache sowie System, Hell und Dunkel in allen
    Hauptansichten auf Lesbarkeit und Persistenz prüfen.
26. Unter **Protokoll > Statuswerte prüfen** alle Invarianten ausführen und
    Ergebnis in UI und `Findora.log` kontrollieren.
27. Ohne Mailquelle starten: kein Dialog, keine Berechtigungsfrage und kein
    Zugriff auf Mail/Outlook.
28. MBOX, mehrere EML/MSG und einen Importordner manuell auswählen;
    Vorabzusammenfassung, Neuimport und ausgeschaltete Überwachung prüfen.
29. Daten- und Modellspeicher getrennt auf ein synthetisches APFS-Testvolume
    migrieren und Altbestand erst nach Bestätigung entfernen.
30. Konfiguriertes Testvolume aushängen; keine leere Datenbank darf entstehen.
31. Mit isoliertem `FINDORA_TEST_ROOT` den Agentenmonitor beobachten: Ohne
    Qwen bleibt der Planner auf `waiting_for_model`; nach Aktivierung müssen
    alle elf Stufen enden und der Wissensgraph wachsen.
32. Qwen-Extraktion und Phi-Zweitprüfung mit ausschließlich synthetischen
    Dokumenten ausführen; Quellen, Seite, Textbereich, Modell und Revision
    stichprobenartig gegen SQLite prüfen.
33. Einen synthetischen Mailthread mit Zusage, Aufgabe und Termin importieren
    und Nachricht-, Anhang-, Claim- und Ereignisverknüpfung kontrollieren.

Der Memory-Pressure-Pfad lässt sich ohne echten Speichermangel kontrolliert
beim App-Start auslösen:

```bash
FINDORA_SIMULATE_MEMORY_PRESSURE=critical \
  FINDORA_DISABLE_DOCUMENT_ACCESS=1 \
  build/Findora.app/Contents/MacOS/Findora
```

Der Regressionstest leitet dasselbe Ereignis von einer Utility-Queue auf den
MainActor weiter. Im Log müssen das kritische Ereignis und die erfolgreiche
Hintergrund-Weiterleitung erscheinen; `_dispatch_assert_queue_fail` oder
`SIGTRAP` dürfen nicht auftreten. Der zweite Schalter verhindert für diesen
Diagnoselauf ausdrücklich Bookmark-Wiederherstellung, Ordnerscan und jeden
PDF-Zugriff.

## Abnahme auf 8 GB

Vor einer externen Version sind Langzeittests mit einem großen synthetischen
Bestand nötig. Zu messen sind Peak-RAM, Speicherdruck, OCR/LLM-Ausschluss,
Erstimport-Fortsetzung, Modellwechsel mit Reindexierung und Stabilität nach
mehreren Neustarts.
