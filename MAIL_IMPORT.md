# Lokaler E-Mail-Import

Findora importiert E-Mails ausschließlich nach einer bewussten Benutzeraktion
unter **E-Mail-Quellen** oder über **Ablage**. Beim App-Start gibt es weder
eine Mail-App-Erkennung noch einen Einrichtungsdialog, eine Berechtigungsfrage
oder einen Zugriff auf interne Apple-Mail-/Outlook-Datenbanken.

## Formate und Parser

- Apple-Mail-Exporte als `.mbox`-Paket oder MBOX-Datei
- einzelne oder mehrfach ausgewählte `.eml`
- einzelne oder mehrfach ausgewählte Outlook-`.msg`
- rekursive Importordner mit diesen Formaten

MBOX und MIME werden gestreamt beziehungsweise in reinem Swift verarbeitet.
Der Outlook-Parser liest das Microsoft Compound Binary File/MSG-Format
ebenfalls direkt in Swift. Dafür wurde keine neue Laufzeitabhängigkeit
ergänzt. MIME unterstützt gefaltete Header, RFC 2047, Base64,
Quoted-Printable, Multipart, verbreitete Zeichensätze, HTML-Text und Anhänge.
HTML wird ohne Skript-, Style- und Tracking-Bestandteile zu durchsuchbarem
Klartext normalisiert.

## Identität und Dubletten

Eine normalisierte, syntaktisch gültige Message-ID wird zusammen mit Absender,
Datum, Betreff und Inhaltshash verifiziert. Ohne Message-ID entsteht die
Identität vollständig aus diesen stabilen Metadaten und SHA-256. Der Inhalt
einer Mail wird einmal gespeichert; mehrere Quellen erhalten eigene
`email_source_links`. Anhänge werden vor Speicherung mit SHA-256 identifiziert,
aber jede Mail-Anhang-Beziehung bleibt separat erhalten.

Nach jedem Import aktualisiert Findora den lokalen Kommunikationsgraphen.
Identische PDF-Anhänge werden über SHA-256 mit bereits vorhandenen PDFs
verknüpft, ohne eine zweite Inhaltskopie anzulegen. Das gilt ebenso, wenn das
PDF erst nach der Mail erscheint. Gleiche Dateinamen mit abweichendem Inhalt
bleiben ausschließlich prüfbare Vorschläge.

## Referenzieren oder archivieren

Vor dem Import zeigt Findora Quellanzahl, erkannte Dateien, Quellgröße und
geschätzten Zusatzbedarf.

- **Referenziert:** Metadaten, normalisierter Text, Index und Beziehungen
  werden gespeichert. Die Quelldatei bleibt am ausgewählten Ort.
- **Archiviert:** Zusätzlich wird eine verifizierte Kopie unter
  `MailArchive/Sources` beziehungsweise `MailArchive/Attachments` angelegt.

Originale werden nie verändert, verschoben oder gelöscht. Das Entfernen einer
Quellenzuordnung löscht weder indexierte Maildaten noch archivierte Originale.

## Anhänge, Abgleich und Suche

Text, Markdown, verschachtelte EML/MSG und PDF werden indexiert. PDFs mit
Textschicht verwenden PDFKit; Bild-PDFs ausschließlich Apple Vision
nicht-destruktiv. Kleine dekorative Inline-Logos werden nicht als eigener
Suchtext aufgebläht.

**Jetzt erneut einlesen** ergänzt neue/geänderte Inhalte, überspringt
Dubletten und kennzeichnet anschließend fehlende Mails als
`Aus Quelle entfernt`. Automatisch gelöscht wird nichts. Importordner können
ausdrücklich überwacht werden; der Standard ist **Aus**. Security-Scoped
Bookmarks werden beim erneuten Zugriff aufgelöst.

Der Filter **Alle / Dokumente / E-Mails / Anhänge** wirkt bereits in FTS-,
Dateinamen- und Vektorabfragen. Treffer tragen Typ, Betreff, Absender, Datum,
Mailbox und bei Anhängen die zugehörige Mail. Die Quellenvalidierung bleibt
fail-closed: Nur tatsächliche Suchergebnisse sind zitierbar.
