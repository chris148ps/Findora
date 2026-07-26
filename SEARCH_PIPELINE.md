# Suchplanung, Retrieval und Antwort

## Drei getrennte Phasen

Findora trennt verbindlich:

1. **Suchplanung:** Nutzerabsicht und Bedingungen verstehen;
2. **Suche:** belegbare Textstellen finden, filtern und bewerten;
3. **Antwort:** ausschließlich die final gefilterten Quellen zusammenfassen.

Alle Phasen laufen lokal. Weder Nutzeranfrage noch Dokumenttext verlassen den
Mac.

## Regelbasierter Mindestplan

`RuleBasedSearchPlanner` erkennt sofort und deterministisch:

- Eigennamen und explizite Organisationen;
- IBANs, Akten-/Vertrags-/Kundennummern;
- Datumsangaben, Jahreszahlen und Geldbeträge;
- bekannte Dokumentarten;
- bekannte Themen und Synonyme.

Eindeutige Entitäten werden harte Bedingungen. Für „Nicos Ausbildung“ entsteht
mindestens:

```text
Pflichtentität: Nico
Thema: Ausbildung
Verknüpfung: UND
```

Ein Dokument ohne Nico-Nachweis in Text, OCR-Text oder Dateiname wird
ausgeschlossen, auch wenn es semantisch zu Ausbildung passt.

## Optionaler lokaler KI-Suchplan

Komplexe natürliche Anfragen werden zusätzlich vom aktiven lokalen
Antwortmodell analysiert. Es erhält nur Anfrage und regelbasierten Mindestplan,
niemals Dokumentinhalt oder Datenbankschema. Einfache Stichwörter und exakte
Kennungen umgehen diesen Schritt.

Der Modelloutput muss ein einzelnes, vollständig ausgefülltes JSON-Schema mit
festen Feldern sein. Unbekannte Felder, fehlende Typen, SQL-Schlüsselwörter,
Semikolon oder SQL-Kommentare werden abgewiesen. Vom Modell erkannte harte
Entitäten werden nur akzeptiert, wenn sie wörtlich in der Nutzeranfrage
nachweisbar sind. Bei jedem Validierungsfehler wird der regelbasierte Plan
verwendet. Modelltext wird niemals als SQL oder Datenbankbefehl ausgeführt.

Unveränderte Pläne werden in einer kleinen sitzungsbezogenen Ablage
wiederverwendet. Es werden höchstens zwölf Cacheeinträge gehalten.

## Retrieval und Mindestschwellen

Aus dem validierten Plan entstehen zwei Kandidatenlisten:

1. SQLite FTS5/BM25 mit sicher escapten Prefix-Begriffen;
2. Kosinus-Ähnlichkeit der Vektoren des **aktiven** Embeddingmodells.

Die Listen werden mit `0,55 × RRF(FTS) + 0,45 × RRF(Vektor)` fusioniert.
Kandidaten benötigen aktuell:

- kombinierten RRF-Score mindestens `0,0065`;
- zusätzlich FTS-Nachweis oder Vektorähnlichkeit mindestens `0,10`.

Gemischte E5-/Fallback-Indizes werden im Dokumentenstatus gewarnt. Die Suche
mischt ihre Vektoren nicht still: `vectorRows` lädt ausschließlich Modell-ID
und Version des aktiven Embedders.

## Pflichtfilter und Re-Ranking

Vor Anzeige und Antwort werden Kandidaten gegen die tatsächlich in SQLite
gespeicherten Chunks geprüft:

- alle Pflichtentitäten müssen im Dokumenttext, OCR-Text oder Dateinamen
  vorkommen;
- Themen müssen durch Thema oder validierte Synonyme belegt sein;
- Person und Thema im selben Chunk ergeben „Sehr passend“;
- Nachweis in verschiedenen Chunks desselben Dokuments ergibt „Passend“;
- nur harter Entitätsnachweis plus schwache semantische Themennähe ergibt
  höchstens „Möglicherweise passend“;
- fehlende Pflichtentität führt immer zum Ausschluss;
- schwache Treffer werden nicht zum Ergebnislimit aufgefüllt.

Regulär erscheinen nur „Sehr passend“ und „Passend“, höchstens ein Treffer pro
Dokument. Unsichere Treffer bleiben in einem getrennten, standardmäßig
eingeklappten Bereich.

Jede Trefferbegründung wird ausschließlich aus nachgewiesenen Entitäten,
Themen, Dateiname, Chunk-/Dokumentnähe, Seite, Textquelle und OCR-Qualität
erzeugt. Das Antwortmodell erzeugt keine Trefferbegründungen.

## Quellengebundene Antwort

Nur reguläre Treffer gelangen in den Antwortprompt. Jeder Auszug erhält eine
opaque Quellen-ID wie `S-001`. Das Systemprompt verbietet erfundene
Dokumente, Namen, Seiten und Quellen. Nach Generierung akzeptiert
`SourceCitationValidator` ausschließlich IDs aus dem aktuellen Trefferbestand;
unbekannte IDs werden entfernt. Eine Antwort ohne mindestens eine gültige
Quelle wird durch die Keine-Belege-Meldung ersetzt.

Bei null regulären Treffern lautet die Suchansicht:

> Keine ausreichend passenden Dokumente gefunden.

Ähnliche oder unsichere Treffer erscheinen erst nach ausdrücklichem Öffnen
ihres getrennten Bereichs.

## Sitzungsbezogene Folgefragen

Marker wie „welche davon“ oder „die gefundenen“ übernehmen fehlende
Pflichtbedingungen aus dem letzten Suchplan. Eine unabhängige Anfrage beginnt
einen neuen fachlichen Kontext. Suchplan- und UI-Verlauf sind auf die letzten
sechs Schritte begrenzt und werden nicht dauerhaft gespeichert oder
exportiert.

## Grenzen

Kleine lokale Modelle können Themen oder Synonyme falsch ergänzen. Deshalb
bleiben regelbasierte Pflichtbedingungen unveränderlich, Modellpläne streng
validiert und alle finalen Treffer belegpflichtig. Die kalibrierten Schwellen
sind konservativ: wenige gute Treffer sind ausdrücklich besser als eine
aufgefüllte Liste schwacher Ergebnisse.

## Deaktivierte Modelle

Ohne aktiviertes Embedding-Modell führt die Suche weiterhin FTS- und
Dateinamensuche aus; semantische Vektorsuche wird nicht aufgerufen und
gespeicherte Embeddings bleiben unverändert. Ohne aktiviertes Antwortmodell
bleiben Retrieval und regelbasierte Suchplanung verfügbar. Die Treffer werden
angezeigt, aber es wird keine lokale KI-Antwort erzeugt.
