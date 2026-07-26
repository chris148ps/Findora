# Datenbankschema

Die aktuelle erwartete Schema-Version ist **12**. `schema_migrations` enthält
jede erfolgreich und transaktional angewendete Version mit Zeitstempel. Die
App führt beim Öffnen nur noch fehlende Migrationen aus; ein Fehler rollt die
jeweilige Migration vollständig zurück.

Schema-Migration 10 ergänzt das PDF-, OCR-, FTS- und Embeddingschema um:

- `documents.content_type`: `pdf`, `email` oder `emailAttachment`
- `mail_import_sources`: Pfad, Bookmark, Modus, Status, Überwachung, Zähler
- `emails`: stabile Identität, Header, Hashes, Texte und Quellenstatus
- `email_recipients`: From/To/Cc/Bcc als strukturierte Adressen
- `email_source_links`: mehrere Mailboxen und Present/Removed-Zustand
- `email_attachments`: SHA-256-deduplizierte Anhangsinhalte
- `email_attachment_links`: jede konkrete Mail-Anhang-Beziehung
- `storage_migrations`: dokumentierter SQL-Migrationsstatus
- `search_source_metadata`: gemeinsame lokale Suchsicht

Mail und Anhang verwenden dieselben `pages`, `chunks`, `chunks_fts` und
`chunk_embeddings` wie PDFs. Cascading Foreign Keys entfernen abhängige
Indexzeilen vollständig, wenn ein PDF nach erfolgreichem Abgleich wirklich
gelöscht wird. Mail- und Anhangdokumente sind von dieser PDF-Bereinigung
ausgeschlossen.

SQLite läuft mit Foreign Keys, WAL und `busy_timeout`. Speicherwechsel
checkpointen und schließen die Verbindung vor der Kopie; die Zielkopie muss
`quick_check = ok` liefern, bevor sie aktiv wird.

Schema-Migration 11 ergänzt den lokalen Kommunikationsgraphen:

- `organizations`, `communication_partners`,
  `communication_partner_aliases`
- `communication_partner_email_links`
- `projects`, `project_document_links`, `project_email_links`
- `document_relations`, `mail_relations`

Sichere Identitäten und gemeinsame Projektreferenzen werden automatisch
verknüpft. Dateinamengleichheit oder schwächere lokale Ähnlichkeit werden nur
als Vorschlag gespeichert.

Schema-Migration 12 ergänzt inkrementelle Analyseversionen:

- `document_analysis_versions` speichert OCR-, Parser-, Chunk-, Embedding-,
  KI-, Personen-, Projekt- und Zusammenfassungs-Version unabhängig je Dokument.
- `analysis_upgrade_jobs` speichert pausier- und fortsetzbare
  Hintergrundaufträge.

Die Migration übernimmt bestehende Dokumente, Seiten, OCR-Texte, Chunks,
Embeddings und Maildaten unverändert. Automatisch nachgeholt werden nur
fehlende Personen- und Projektanalysen. OCR, Embeddings und ein kompletter
Indexaufbau benötigen weiterhin eine ausdrückliche Nutzeraktion.
