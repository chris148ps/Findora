# Findora -- CODEX_WORKFLOW.md

> **Verbindliche Arbeitsanweisung für alle zukünftigen Codex-Aufträge**

## 1. Vor jedem Auftrag

Codex muss immer zuerst:

1. `AGENTS.md` lesen.
2. Diese Datei (`docs/CODEX_WORKFLOW.md`) lesen.
3. Prüfen:
   - `git status`
   - `git branch --show-current`
   - `git pull --ff-only`
4. Prüfen, dass kein unbeabsichtigter Branch verwendet wird.
5. Projektdokumentation auf offene Punkte prüfen.

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
- Keine Veröffentlichung.
- Kein Push.
- Kein Tag.
- Kein Release.
- Sicherheits- und Architekturvorgaben aus `AGENTS.md` beachten.
- Bei größeren Änderungen Dokumentation aktualisieren.

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

**Kein `git push`.** Der Push erfolgt ausschließlich durch den Projektinhaber.

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
- Hinweis, dass kein Push/Tag/Release erfolgt ist

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

Push nur manuell durch den Projektinhaber.

---

## 8. Grundsatz

Diese Datei ist für zukünftige Codex-Aufträge verbindlich. Änderungen an diesem Workflow sollen ebenfalls in dieser Datei dokumentiert werden.
