# Datenbankschema

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

