# Findora-Roadmap

## Umgesetzt

- lokale PDF-/OCR-Pipeline mit Apple Vision als installationsfreiem Standard
- lokale FTS-/Embedding-Suche und fail-closed Quellenvalidierung
- manueller MBOX-, EML- und Outlook-MSG-Import
- E-Mails und Anhänge als gemeinsam durchsuchbare Inhalte
- referenzierte und archivierte Mailquellen
- optionale, standardmäßig deaktivierte Importordnerüberwachung
- unabhängiger, sicher migrierbarer Daten- und Modellspeicher
- SHA-256-Dokumentabgleich mit drei Richtlinien für entfernte PDFs

## Später, nicht Bestandteil dieser Umsetzung

- direkte Live-Anbindung an interne Apple-Mail- oder Outlook-Profile
- PST-/OST-Import und S/MIME-/PGP-Entschlüsselung
- automatische Mail-App-Erkennung beim Start
- Cloud-KI, Telemetrie oder externe Inhaltsübertragung
- HNSW-Vektorindex und verschlüsselter Anwendungsindex

Vor einer externen Veröffentlichung bleiben Notarisierung, SBOM, heterogene
reale MSG/MBOX-Abnahmetests und ein Langzeittest mit großem synthetischem
Bestand gesonderte Freigabepunkte.

