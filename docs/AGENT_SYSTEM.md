# Agentensystem

Stand: 30. Juli 2026

## Rollen

Findora führt elf klar abgegrenzte Rollen:

- Planner-Agent: beansprucht den ersten Wissensjob und startet die lokal
  validierte Gesamtanalyse;
- Import-Agent: meldet inkrementelle Dokument- und Mailimporte;
- OCR-Agent: meldet PDFKit-, Apple-Vision- und optionale lokale
  Tesseract-Verarbeitung;
- Vision-Agent: analysiert ausdrücklich ausgewählte Problemseiten lokal;
- Extraktions-Agent: prüft materialisierte Entitäten, Fakten, Relationen und
  beleggebundene Zusammenfassungen;
- Kommunikations-Agent: erzeugt Threads, Teilnehmer-, Anhangs- und
  beleggebundene Ereignisbeziehungen;
- Projekt-Agent: übernimmt nur Kandidaten mit mehreren starken Signalen;
- Qualitäts-Agent: prüft Belege, Entitätsauflösung und Konflikte;
- Erfahrungs-Agent: erzeugt ab mindestens drei belegten Claims vorgeschlagene
  Statistiken und Muster;
- Antwort-Agent: kombiniert Wissens-, FTS- und Vektorquellen und validiert
  Quellen-IDs;
- Wartungs-Agent: invalidiert veraltetes Wissen und baut betroffene Teilgraphen
  neu auf.

## Kommunikationsgrenze

Agenten rufen einander nicht direkt auf. `KnowledgeAgentSystem` liest den
persistenten Abhängigkeitsgraphen aus `knowledge_jobs`. Ergebnisse werden nur
über typisierte Services und validierten SQLite-Zustand weitergegeben.
Modellcode besitzt keinen Datenbankzugriff.

## Laufzeit und Fehler

Ein Job wird atomar von `pending` nach `running` beansprucht. Fehlende
Modellgewichte führen zu `waiting_for_model`; nach Modellaktivierung wird der
Job wieder aufgenommen. Technische Fehler werden höchstens dreimal mit
Zeitabstand versucht. Abhängige Jobs starten erst nach erfolgreichem
Vorgänger.

`agent_runs` und `audit_log` enthalten Rolle, Job-ID, Zustand, Zähler,
Fehlerkategorie und Revision, aber keinen Dokumenttext, Prompt oder
Modelloutput.

## 8-GB-Grenze

`LocalGenerativeTaskGate` serialisiert Wissensextraktion, Phi-Prüfung,
Suchplanung, Antwort und optische Analyse. Die Extraktionskoordination entlädt
Qwen vor Phi. Kritischer Speicherdruck pausiert neue Agentenjobs und entlädt
aktive generative Laufzeiten.

## Monitor

Der Entwicklerbereich zeigt alle Rollen, Zustand, aktuelle Jobart,
technischen Detailtext, Zähler und Aktualisierungszeit. Import, OCR, Vision und
Antwort melden ihre bestehenden Services an denselben Monitor.
