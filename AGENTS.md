# Findora – Arbeitsregeln

Diese Datei gilt für alle Arbeiten im Repository.

## Vor jedem Auftrag

1. `AGENTS.md` und `docs/CODEX_WORKFLOW.md` vollständig lesen.
2. `git status`, den aktuellen Branch und `git pull --ff-only` prüfen.
3. Die für den Auftrag relevanten Fach- und Sicherheitsdokumente lesen.
4. Vorhandene Nutzeränderungen erhalten und den Auftrag möglichst klein halten.

## Architektur- und Sicherheitsgrenzen

- Findora verarbeitet private PDFs und Suchdaten lokal. Dokumentinhalte,
  Suchanfragen, Embeddings und Antworten dürfen nicht an externe Dienste
  übertragen werden.
- Original-PDFs nicht verändern, verschieben oder löschen, sofern der Nutzer
  die konkrete Dateiaktion nicht ausdrücklich beauftragt und bestätigt hat.
- Apple Vision bleibt der installationsfreie OCR-Standard. Homebrew,
  Tesseract, OCRmyPDF oder Poppler dürfen beim normalen Start weder geprüft
  noch installiert werden. Externe OCR-Komponenten erst nach ausdrücklicher
  Auswahl oder einem echten Fallback-Bedarf auflösen.
- Produktive App-Daten unter `~/Library/Application Support/Findora` und
  `~/Library/Logs/Findora` nicht für Tests verwenden, migrieren oder löschen.
- Isolierte App-Starts müssen `FINDORA_TEST_ROOT` auf ein mit
  `mktemp -d "${TMPDIR%/}/Findora-Tests.XXXXXX"` erzeugtes Verzeichnis unter
  dem echten macOS-Temporärverzeichnis setzen. Vor der ersten UI-Aktion ist
  mit `lsof` nachzuweisen, dass weder ein produktiver noch ein benutzerdefiniert
  konfigurierter Daten- oder Modellpfad geöffnet wurde. `/tmp` darf nicht
  ungeprüft verwendet werden, weil Findora absichtlich nur den von
  `FileManager.temporaryDirectory` gelieferten Teilbaum als Testwurzel
  akzeptiert.
- Falls trotz dieser Schutzmaßnahmen unbeabsichtigt ein produktiver oder
  benutzerdefinierter Findora-Pfad geöffnet wurde, den betreffenden Prozess
  sofort beenden und die Auswirkung read-only prüfen. Codex darf danach ohne
  erneute Nutzerfreigabe weiterarbeiten, committen und einen bereits
  autorisierten Push ausführen, wenn nachweislich nur automatisch erzeugte
  technische Metadaten betroffen sind (beispielsweise Integritätszeitstempel
  von Modellen oder SQLite-WAL-/SHM-Verwaltung), `quick_check`,
  `integrity_check` und die Fremdschlüsselprüfung fehlerfrei sind und keine
  Dokument-, OCR-, Such-, Mail-, Bookmark- oder Einstellungsdaten geändert
  wurden. Der Vorfall und die Prüfergebnisse müssen im Abschlussbericht stehen.
  Bei inhaltlichen, nicht eindeutig begrenzbaren oder destruktiven Änderungen
  bleibt eine neue ausdrückliche Nutzerentscheidung erforderlich.
- Keine allgemeine Telemetrie, Cloud-KI oder automatische externe Übertragung
  ergänzen. Einzige ausdrücklich freigegebene Ausnahme sind lokal bereinigte
  Crashberichte über Apple Mail an den fest konfigurierten Findora-Support.
  Diese Funktion ist standardmäßig aktiviert, in den Einstellungen jederzeit
  abschaltbar und darf keine Dokumentinhalte, Suchanfragen, OCR-Texte,
  Dateinamen oder vollständigen privaten Pfade enthalten.
- Die Modulgrenzen aus `ARCHITECTURE.md`, die Schutzregeln aus `SECURITY.md`
  und die Datenschutzregeln aus `PRIVACY.md` einhalten.

## Pflichtprüfungen

Änderungen proportional zum Risiko prüfen. Für produktive Codeänderungen sind,
sofern technisch möglich, mindestens vorgesehen:

```bash
swift test
./scripts/check-product-name.sh
./scripts/check-localization.sh
./scripts/build-app.sh release
codesign --verify --deep --strict build/Findora.app
git diff --check
```

Bei Nebenläufigkeitsänderungen zusätzlich Swift Strict Concurrency mit
Warnungen als Fehler prüfen. Start- und Smoke-Tests müssen den Dokumentzugriff
deaktivieren oder ausschließlich synthetische Testdaten verwenden.

## Git und GitHub

- Nach erfolgreichen Prüfungen Änderungen nachvollziehbar committen.
- Pushes sind erlaubt, wenn der Nutzer sie ausdrücklich autorisiert oder ein
  vollständig mit GitHub synchronisiertes Ergebnis beauftragt hat.
- Vor einem Push Ziel-Repository, Branch und ausgehende Commits prüfen.
- Keine Tags, GitHub Releases, Notarisierung oder externe Veröffentlichung
  ohne gesonderten ausdrücklichen Auftrag.
- Abschlussberichte nennen Branch, Commit, Push-Ziel, Prüfungen und offene
  Risiken.
