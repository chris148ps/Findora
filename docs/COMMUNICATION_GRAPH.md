# Interne Mail- und Dokumentverknüpfungen

Die früher sichtbaren Bereiche **Kommunikationspartner** und **Projekte** sind
für ein späteres Update zurückgestellt. Sie erscheinen weder in der
Navigation noch als Sucherweiterung oder in den Dokumentdetails. Die
automatische Projektbildung ist deaktiviert. Vorhandene interne Tabellen
werden nicht gelöscht, damit Bestandsdaten nicht durch eine destruktive
Migration verloren gehen.

## Lokales Modell

Findora erzeugt aus importierten Absendern und Empfängern
`communication_partners`. Normalisierte E-Mail-Adressen sind die sichere
Identität. Alias-Schreibweisen derselben Adresse werden separat erhalten.
Firmen-Domains erzeugen Organisationen; verbreitete private Mail-Domains
werden nicht automatisch als Organisation interpretiert.

Die Adressableitung ist ebenfalls deaktiviert. Bestehende Partner-,
Organisations- und Projektzeilen bleiben ausschließlich aus
Kompatibilitätsgründen erhalten.

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

Partner- und Projektnamen erweitern die Suche derzeit nicht. Dokumentdetails
zeigen nur direkte lokal ermittelte Mail-/Dokumentrelationen einschließlich
Status und Konfidenz.

## Datenschutz

Der Kommunikationsgraph liegt ausschließlich in der Findora-SQLite-Datenbank.
Adressdaten, Inhalte, Relationen und Suchanfragen werden nicht übertragen und
nicht in Inhaltsprotokolle geschrieben.
