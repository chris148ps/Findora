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
- Keine Telemetrie, Cloud-KI oder automatische externe Übertragung ergänzen.
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
