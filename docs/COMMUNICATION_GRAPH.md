# Kommunikationspartner, Projekte und Verknüpfungen

## Lokales Modell

Findora erzeugt aus importierten Absendern und Empfängern
`communication_partners`. Normalisierte E-Mail-Adressen sind die sichere
Identität. Alias-Schreibweisen derselben Adresse werden separat erhalten.
Firmen-Domains erzeugen Organisationen; verbreitete private Mail-Domains
werden nicht automatisch als Organisation interpretiert.

Die Übersichten **Kommunikationspartner** und **Projekte** zeigen die lokal
abgeleiteten Beziehungen. Pro Partner werden E-Mail-, PDF-, Angebots-,
Rechnungs- und Bildzähler sowie die letzte Aktivität angezeigt.

## Verknüpfungsregeln

- Ein Mail-Anhang und ein vorhandenes PDF mit identischem SHA-256 verweisen auf
  dasselbe Dokument und erhalten eine sichere automatische Relation.
- Die Regel funktioniert unabhängig davon, ob zuerst die Mail oder zuerst das
  PDF importiert wird.
- Eine gemeinsame eindeutige Projektreferenz, beispielsweise `PRJ-1001`, darf
  automatisch verknüpfen.
- Hohe lokale Textähnlichkeit darf automatisch verknüpfen; mittlere
  Ähnlichkeit bleibt ein Vorschlag.
- Gleicher Dateiname bei unterschiedlichem SHA-256 ist immer nur ein Vorschlag.
- E-Mails mit derselben Conversation-ID werden als Unterhaltung verknüpft.

Alle Evidenz wird lokal aus Betreff, Dokumenttext, Dateiname, strukturierten
Adressen und lokalen Embeddings abgeleitet. Es gibt keine Cloud-Abfrage.

## Suche und Details

Partner- und Projektnamen erweitern die gemeinsame Suche über E-Mails, PDFs
und Anhänge. Ein Graph-Treffer wird als **Verknüpfter Kontext** gekennzeichnet.
Die Detailansicht zeigt erkannte Partner, Projekte sowie verknüpfte E-Mails
und Dokumente einschließlich Status und Konfidenz.

## Datenschutz

Der Kommunikationsgraph liegt ausschließlich in der Findora-SQLite-Datenbank.
Adressdaten, Inhalte, Relationen und Suchanfragen werden nicht übertragen und
nicht in Inhaltsprotokolle geschrieben.
