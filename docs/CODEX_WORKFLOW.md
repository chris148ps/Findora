# Findora -- CODEX_WORKFLOW.md

> **Verbindliche Arbeitsanweisung für alle zukünftigen Codex-Aufträge**

## 1. Vor jedem Auftrag

Codex muss immer zuerst:

1. `AGENTS.md` lesen.
2. Diese Datei (`docs/CODEX_WORKFLOW.md`) lesen.
3. `docs/FINDORA_MASTER_SPECIFICATION.md` als verbindliche langfristige
   Zielarchitektur vollständig lesen.
4. Prüfen:
   - `git status`
   - `git branch --show-current`
   - `git pull --ff-only`
5. Prüfen, dass kein unbeabsichtigter Branch verwendet wird.
6. `docs/PROJEKTSTATUS.md` und `docs/NEXT_TASK.md` heranziehen, um
   Zielarchitektur, implementierten Stand und offene Abnahmen klar zu trennen.
7. Projektdokumentation auf offene Punkte prüfen.

### Standardbefehle

```bash
git status
git branch --show-current
git pull --ff-only
```

---

## 2. Während der Entwicklung

Verbindlich:

- Keine Original-PDFs verändern, sofern der Auftrag dies nicht ausdrücklich verlangt.
- Keine produktiven Daten löschen.
- Keine Tags, Releases, Notarisierung oder externe Veröffentlichung ohne
  ausdrücklichen Auftrag.
- Pushes nur, wenn der Nutzer sie ausdrücklich autorisiert oder ein vollständig
  mit GitHub synchronisiertes Ergebnis beauftragt hat.
- Sicherheits- und Architekturvorgaben aus `AGENTS.md` beachten.
- Neue Architektur- und Produktentscheidungen an
  `docs/FINDORA_MASTER_SPECIFICATION.md` ausrichten; nicht implementierte
  Zielmerkmale nicht als bestehenden Funktionsumfang darstellen.
- Bei größeren Änderungen Dokumentation aktualisieren.
- GUI- und Smoke-Tests nur mit einer `FINDORA_TEST_ROOT` unter dem echten
  macOS-`$TMPDIR` starten und vor der ersten UI-Aktion per `lsof` bestätigen,
  dass keine produktive oder benutzerdefinierte Findora-Datenbank geöffnet ist.
- Nach einem unbeabsichtigten produktiven Zugriff gelten die
  Fortsetzungsregeln aus `AGENTS.md`: sofort stoppen, read-only auswerten und
  den Vorfall dokumentieren. Bei ausschließlich begrenzten technischen
  Metadatenänderungen und fehlerfreien SQLite-Prüfungen darf Codex ohne
  Rückfrage fortfahren sowie einen bereits autorisierten Commit und Push
  abschließen; inhaltliche oder unklare Änderungen erfordern weiterhin eine
  ausdrückliche Nutzerentscheidung.

---

## 3. Nach Abschluss

Immer durchführen:

```bash
git status
git log --oneline --decorate -5
```

Wenn erfolgreich:

```bash
git add -A
git commit -m "<passende Commit-Nachricht>"
```

Wenn der Nutzer den Push ausdrücklich autorisiert hat:

```bash
git push
```

Vorher Ziel-Repository, Branch und ausgehende Commits prüfen.

---

## 4. Pflichtprüfungen

Sofern technisch möglich:

- Testsuite
- Swift Strict Concurrency (`warnings-as-errors`)
- Release-Build
- Codesign
- Launch-/Smoke-Test
- keine neuen Crashmarker

---

## 5. Abschlussbericht

Immer enthalten:

- Ursache
- Lösung
- geänderte Dateien/Bereiche
- Testergebnisse
- Commit-SHA
- Branch
- offene Risiken
- Push-Ziel beziehungsweise Hinweis, dass kein Push erfolgt ist
- Hinweis, dass kein Tag oder Release erfolgt ist

---

## 6. Codex-Aufträge

Jeder von ChatGPT erzeugte Codex-Auftrag muss:

- vollständig in Markdown sein
- vollständig kopierbar sein
- zusätzlich als herunterladbare `.md`-Datei bereitgestellt werden

Keine gekürzten Aufträge.

---

## 7. Git-Workflow zwischen Mac mini und MacBook

### Arbeitsbeginn

```bash
git status
git branch --show-current
git pull --ff-only
```

### Arbeitsende

```bash
git status
git add -A
git commit -m "<Beschreibung>"
```

Push nur nach ausdrücklicher Autorisierung des Nutzers.

---

## 8. Grundsatz

Diese Datei ist für zukünftige Codex-Aufträge verbindlich. Änderungen an diesem Workflow sollen ebenfalls in dieser Datei dokumentiert werden.
