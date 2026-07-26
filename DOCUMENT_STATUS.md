# Dokumentenstatus und Zählersemantik

SQLite ist die einzige fachliche Quelle der Statusanzeige. `statistics()`
liest einen vollständigen Snapshot aus einer Abfrage; die App führt keine
separaten In-Memory-Zähler. Erfolgreiche Transaktionen veröffentlichen danach
ein Statusereignis. Die MainActor-UI bündelt Ereignisse für 300 ms; ein
30-Sekunden-Abgleich ist nur das Sicherheitsnetz.

## Einheiten und mathematische Beziehungen

`PDFs insgesamt` zählt aktuelle Pfad-Jobs des letzten Scans, nicht eindeutige
SHA-256-Inhalte. Byteidentische Kopien zählen daher als eigene PDFs und
zusätzlich als Duplikatpfade. Nicht mehr vorhandene `retired`-Jobs sind
historisch und nicht in `PDFs insgesamt` enthalten.

Die aktuellen Jobzustände sind exklusiv:

```text
PDFs insgesamt
= Indexiert + In Warteschlange + In Bearbeitung
 + Technische Fehler + derzeit nicht verfügbare PDFs
```

`Pausiert` ist ein Overlay über wartende und laufende Jobs und wird nicht
addiert. `Übersprungen` bezeichnet frühere, aus dem aktuellen Scan entfernte
Jobs und wird ebenfalls nicht addiert.

Indexierte PDFs erhalten genau eine Klasse:

```text
Indexiert
= Bereits vollständig durchsuchbar
 + Durch OCR ergänzt
 + Ohne verwertbaren Text
 + Weitere indexierte Sonderfälle
```

Ein gemischtes PDF mit mindestens einer verwendeten OCR-Seite zählt einmal als
`Durch OCR ergänzt`. Seiten werden zusätzlich nach `PDF-Text`, `OCR-Text`,
`manuellem Text` oder `ohne verwertbaren Text` getrennt. OCR-Retry-Zeilen sind
Diagnosedaten und erhöhen weder Dokument- noch Seitenerfolge.

`Embeddings gesamt` zählt Vektorzeilen, nicht Chunks:

```text
Embeddings gesamt
= E5-Embeddings + Fallback-Embeddings + Weitere Embeddings
```

Ein Chunk mit zwei Modellvektoren zählt als ein Chunk und zwei Embeddings.

## Inventar aller technischen Werte

Alle Werte werden beim Öffnen, nach Statusereignissen und nach einem Neustart
neu aus SQLite aggregiert. „Erhöht/verringert“ bedeutet deshalb eine Änderung
der genannten persistierten Zeilen, nicht die Mutation eines Zählers.

| Anzeige | Einheit und SQLite-Grundlage | Erhöhung/Verringerung, Überlappung |
|---|---|---|
| PDFs insgesamt | PDF-Pfade; `processing_jobs`, außer `retired` | Scan fügt/reaktiviert Jobs; Entfernung setzt `retired`; exklusiver Nenner |
| Indexiert | PDF-Pfade; Jobs `state=indexed` | atomarer Abschluss von `indexDocument`; Neuplanung/Reset entfernt den Zustand |
| In Warteschlange | Jobs; `discovered`, `waitingForStability`, `ocrQueued` | Scan/Retry/Reset plant ein; Start oder Abschluss plant aus |
| In Bearbeitung | Jobs; `extracting`, `ocrRunning`, `indexing` | Verarbeitungsstart erhöht, Abschluss/Fehler vermindert |
| Pausiert | Jobs; Warteschlange plus Bearbeitung bei globaler Pause | Overlay, absichtlich nicht exklusiv |
| Übersprungen | frühere Jobs; `retired` | fehlender Pfad wird beim Scan aus dem aktiven Bestand genommen; nicht in PDFs insgesamt |
| Technische Fehler | Jobs; `failed` | fehlgeschlagener Lauf; Retry/Erfolg entfernt den Zustand |
| Fehlende Dateien | Pfade; `retired` oder `unavailable` | Scan/Verfügbarkeit; kann historische Pfade enthalten |
| Duplikate | zusätzliche aktuelle PDF-Pfade je gleichem `content_hash` | nach Hashpersistierung; verschwindet bei Entfernung/Inhaltsänderung |
| Bereits vollständig durchsuchbar | PDFs; indexierter Job, `text_layer_present=1`, keine verwendete OCR-Seite | exklusive Indexklasse |
| Durch OCR ergänzt | PDFs; indexierter Job mit mindestens einer nichtleeren Seite `text_source=ocr` | exklusive Indexklasse; ein PDF zählt einmal |
| Ohne verwertbaren Text | PDFs; indexierter Job ohne nichtleeren Seitentext und ohne OCR-Text | exklusive Indexklasse |
| Weitere indexierte Sonderfälle | PDFs; Restklasse, etwa nur manueller oder älterer nicht eindeutig zuordenbarer Text | exklusive Indexklasse |
| OCR erforderlich – PDFs | PDFs; aktuelle Jobs `ocrQueued` oder `ocrRunning` | operative Teilmenge vor Abschluss; kann mit Warteschlange/Bearbeitung überlappen |
| OCR fehlgeschlagen – PDFs | PDFs; `failed` mit `last_stage=ocrRunning` | nicht indexiert; Teilmenge technischer Fehler |
| Seiten mit PDF-Text | Seiten je aktuellem indexiertem PDF-Pfad; `text_source=extracted`, Text nicht leer | exklusive Textquellenklasse |
| Seiten mit OCR-Text | Seiten je aktuellem indexiertem PDF-Pfad; `text_source=ocr`, Text nicht leer | exklusive Textquellenklasse; Versuche zählen nicht |
| Seiten mit manuellem Text | Seiten je aktuellem indexiertem PDF-Pfad; `text_source=manual`, Text nicht leer | exklusive Textquellenklasse |
| Seiten ohne verwertbaren Text | Seiten je aktuellem indexiertem PDF-Pfad; Text leer | exklusive Textquellenklasse |
| OCR erfolgreich – Seiten | Seiten; `ocr_page_quality.status=good` aktueller indexierter PDFs | Qualitätszustand, kann einer OCR-Textseite entsprechen |
| OCR-Seiten zur Prüfung | Seiten; `ocr_page_quality.status=review` | Qualitätszustand |
| OCR wahrscheinlich fehlgeschlagen | Seiten; `ocr_page_quality.status=likelyFailed` | Qualitätszustand |
| Chunks | Textabschnitte eindeutiger aktiver Dokumentinhalte; `chunks` | Indexaufbau erzeugt, Suchindexreset ersetzt |
| Embeddings gesamt | Vektoren; `chunk_embeddings` aktiver Chunks | Indexaufbau/Modellwechsel erzeugt, Reset ersetzt |
| E5-Embeddings | Vektoren mit E5-Modell-ID | Teilmenge Embeddings |
| Fallback-Embeddings | Vektoren mit `builtin-token-hash` | Teilmenge Embeddings |
| Weitere Embeddings | Vektoren aller anderen Modell-IDs | Teilmenge Embeddings |
| Zu prüfende leere Seiten | Seiten; aktuelle `page_content_analysis` ohne abschließende Entscheidung | Analyse/Entscheidung |
| Bestätigte leere PDFs | PDFs; alle aktuellen Analyseseiten leer klassifiziert | Dokumentaggregation aus Seiten; keine OCR-Erfolgszahl |
| Sicher leere Seiten | Seiten; `safelyEmpty` | automatische Analyse, manuelle Gegenentscheidung schließt aus |
| Vermutlich leere Seiten | Seiten; `probablyEmpty` | automatische Analyse, manuelle Gegenentscheidung schließt aus |
| OCR-Nachbearbeitung aktiv | Jobs; `ocrRunning` mit Retry-Fortschritt | operativer Overlay-Zustand, keine Seitenzahl |
| OCR-Prüffälle – Seiten | Seiten; fachliche Prüffälle in aktueller Analyse | kann Qualitätsprüfung ergänzen, stammt aber aus Wartungsanalyse |
| Manuell als nicht leer bestätigt | Seiten; `user_decision=notEmpty` | manuelle Entscheidung |
| OCR ohne Ergebnis – Seiten | Seiten; `status=ocrNoResult` | finaler aktueller Seitenzustand, nicht Zahl der Versuche |
| Manuell korrigierte Seiten | Seiten; `status=manuallyCorrectedText` | manuell gespeicherter Seitentext |
| Manuell erfasste Seiten | Seiten; `status=manuallyEnteredText` | manuell gespeicherter Seitentext |

## Reset und Neustart

- **Suchindex neu aufbauen:** Dokument-, Textquellen-, OCR-Qualitäts- und
  Wartungswerte bleiben erhalten; Chunks und Embeddings werden transaktional
  ersetzt.
- **OCR und automatische Analysen zurücksetzen:** OCR-Qualität, Retry- und
  automatische Analysewerte werden entfernt und aktive Jobs neu eingeplant.
  Manuelle Entscheidungen und manuelle Texte bleiben erhalten.
- **Vollständigen Dokumentindex löschen:** Dokument-, Seiten-, Job-, OCR-,
  Such- und Wartungszeilen werden entfernt; alle zugehörigen Zähler werden
  null. PDFs, Modelle und Einstellungen bleiben unverändert.

Es gibt keine gespeicherten Zählerspalten und deshalb keine Zählermigration.
Bestehende Daten werden anhand des aktuellen Job-Hash, der Dokumentversion und
der bereits transaktional migrierten `pages.text_source`-Spalte neu
klassifiziert. Alte Pfadversionen sind ausgeschlossen.

## Diagnose

**Protokoll > Statuswerte prüfen** aggregiert frisch aus SQLite und prüft:

- aktuelle Jobzustände gegen `PDFs insgesamt`;
- exklusive Indexklassen gegen `Indexiert`;
- Embeddingtypen gegen `Embeddings gesamt`;
- nichtnegative Hauptwerte.

Das Ergebnis wird in `~/Library/Logs/Findora/Findora.log`
protokolliert und in der UI angezeigt. Bei einer Abweichung entsteht zusätzlich
ein technischer Protokolleintrag. Die Diagnose löscht und verändert weder PDFs
noch Dokumentdaten.
