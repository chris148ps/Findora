# Wissensvalidierung und Halluzinationsschutz

Stand: 30. Juli 2026

## Fail-closed Speicherpfad

Ein Modell besitzt keinen Datenbankzugriff. Es liefert Bytes an
`KnowledgeExtractionCoordinator`. Erst nach allen Prüfungen erhält
`SQLiteDatabase.storeValidatedKnowledge` ein typisiertes Ergebnis.

Prüfreihenfolge:

1. syntaktisch gültiges JSON-Objekt,
2. keine unbekannten Top-Level-Felder,
3. unterstützte Schema-Version,
4. eindeutige Kandidaten- und Beleg-IDs,
5. Pflichtfelder, Confidence und Datentypen,
6. existierende Dokument-, Seiten- und Chunkreferenz,
7. wörtlicher Beleg im tatsächlichen Seitentext,
8. exakter UTF-16-Zeichenbereich, sofern angegeben,
9. gültige normalisierte Bounding Box,
10. normalisierbare Werte und Einheiten,
11. mindestens ein Beleg pro Kandidat,
12. eine SQLite-Transaktion für den vollständigen Lauf.

Bei einem ungültigen Versuch wird nichts gespeichert. Ein korrigierender
Prompt darf die Ausgabe einmal vollständig neu erzeugen.

## Aussagentypen und Zweitprüfung

`explicit_fact` und `calculated_fact` können nach Quellenprüfung aktiv werden.
`model_inference` bleibt ausschließlich ein nicht faktischer
`proposed/uncertain`-Prüfkandidat und wird weder im aktiven Wissensgraph noch
für Antworten, Projekte, Kommunikation oder Erfahrungswissen verwendet. Ein Modell darf weder
`user_confirmed` noch `externally_verified` behaupten. Abgelehnte Aussagen und
Nutzerkorrekturen werden beim Upsert nicht überschrieben.

Bei Unsicherheit kann ein separates Modell dieselben Originalbelege mit einem
neutralen Schema sehen. Es erhält nicht die Begründung des ersten Modells. Nur
übereinstimmende Fakten und Relationen werden übernommen.

## Antworten

Die Suche kombiniert aktive `verified`/`supported` Wissensclaims mit FTS,
Dateinamen und optionaler Vektorsuche. Ein Wissentreffer verweist auf den
Originalbeleg und die Seite. `SourceCitationValidator` verwirft erfundene
Quellen-IDs.

`KnowledgeAnswerClassifier` kennzeichnet das sichtbare Ergebnis als
`Gesichert`, `Berechnet`, `Wahrscheinlichkeit`, `Erfahrung`, `Konflikt` oder
`Unbekannt`. Ohne mindestens eine reale Quelle und eine gültige Quellen-ID
lautet die Klasse immer `Unbekannt`.

Automatisch gebildete Projekte verknüpfen ausschließlich genau die validierten
Belege, die von den angenommenen starken Projektsignalen referenziert werden.
Ein bloßer Dokumentbezug oder ein häufiger Personenname reicht nicht aus.
