# Interne Mail- und Dokumentverknüpfungen

Der Kommunikationsgraph ist eine interne lokale Wissensschicht. Threads,
Nachrichten, Teilnehmer, Anhänge und belegte Ereignisse sind im
Entwicklerbereich prüfbar. Bestehende kompatible Partner- und Projekttabellen
werden nicht destruktiv ersetzt.

## Lokales Modell

Findora erzeugt aus importierten Absendern und Empfängern
`communication_partners`. Normalisierte E-Mail-Adressen sind die sichere
Identität. Alias-Schreibweisen derselben Adresse werden separat erhalten.
Firmen-Domains erzeugen Organisationen; verbreitete private Mail-Domains
werden nicht automatisch als Organisation interpretiert.

Die Wissensschicht kann Adressen als Entitäts- und Projektsignal verwenden.
Automatische Zuordnungen verlangen starke Mehrfachsignale; häufige Namen und
bloße Betreffähnlichkeit reichen nicht.

## Verknüpfungsregeln

- Ein Mail-Anhang und ein vorhandenes PDF mit identischem SHA-256 verweisen auf
  dasselbe Dokument und erhalten eine sichere automatische Relation.
- Die Regel funktioniert unabhängig davon, ob zuerst die Mail oder zuerst das
  PDF importiert wird.
- Hohe lokale Textähnlichkeit darf automatisch verknüpfen; mittlere
  Ähnlichkeit bleibt ein Vorschlag.
- Gleicher Dateiname bei unterschiedlichem SHA-256 ist immer nur ein Vorschlag.
- E-Mails mit derselben Conversation-ID werden als Unterhaltung verknüpft.

Alle Evidenz wird lokal aus Betreff, Dokumenttext, Dateiname, strukturierten
Adressen und lokalen Embeddings abgeleitet. Es gibt keine Cloud-Abfrage.

## Suche und Details

Die hybride Suche kann aktive belegte Wissensclaims zusammen mit direkten
lokalen Mail-/Dokumentrelationen verwenden. Jede Relation zeigt Status,
Konfidenz und Originalbeleg.

## Kommunikationsereignisse

Nach der quellenvalidierten Extraktion materialisiert der
Kommunikations-Agent Entscheidungen, Zusagen, Ablehnungen, offene Fragen,
Aufgaben, Termine, Freigaben, Anforderungen, technische Änderungen und
Verantwortlichkeiten. Ein Ereignis verweist zwingend auf Nachricht und Claim;
ohne aktiven `verified`- oder `supported`-Claim wird nichts gespeichert.

Anhänge bleiben über Nachrichten-, Anhangs-, Dokument- und SHA-256-Identität
dauerhaft verbunden.

## Datenschutz

Der Kommunikationsgraph liegt ausschließlich in der Findora-SQLite-Datenbank.
Adressdaten, Inhalte, Relationen und Suchanfragen werden nicht übertragen und
nicht in Inhaltsprotokolle geschrieben.
