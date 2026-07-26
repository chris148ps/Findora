# Findora – Produkt-Roadmap

Stand: 26.07.2026

## Grundsätze

- Lokale Verarbeitung ohne Cloud-Zwang
- Original-PDFs standardmäßig unverändert
- Apple Vision als bevorzugte OCR-Engine auf macOS
- Tesseract/OCRmyPDF nur bei Bedarf
- SQLite, Modelle und Index lokal je Gerät
- Quellcode-Synchronisation über Git
- Keine Veröffentlichung, kein Tag und kein Release ohne separate Freigabe
- Codex liest vor jeder Änderung `AGENTS.md` und `docs/CODEX_WORKFLOW.md`

---

# Version 1.0 – Erste verkaufsfähige Mac-Version

## Kernfunktionen

- PDF-Ordner auswählen und überwachen
- digitale Textschichten erkennen
- Apple-Vision-OCR
- optional Tesseract/OCRmyPDF
- nicht-destruktive OCR mit Speicherung in SQLite
- optional dauerhafte OCR-Textschicht in PDF
- SHA-256-basierte Dokumentidentität
- Umbenennungen und Verschiebungen erkennen
- Duplikate erkennen und sicher über den Papierkorb entfernen
- leere Seiten erkennen, prüfen und sicher bearbeiten
- automatische OCR-Nachbearbeitung
- manuelle OCR-Vorschau und Textkorrektur
- klassische Volltextsuche
- semantische Suche mit lokalem Embedding-Modell
- lokale KI-Antworten mit Quellen
- KI-gestützte Suchplanung
- sitzungsbezogene Folgefragen
- Dokumentenstatus und Dokumentenwartung
- Deutsch und Englisch
- System-, Hell- und Dunkelmodus
- installierte Modelle aktivieren, deaktivieren und löschen

## Vor Veröffentlichung noch erforderlich

- Markenprüfung `Findora`
- professionelles App-Icon
- Onboarding
- Hilfe und FAQ
- Datenschutz- und Support-Webseite
- App-Store-Screenshots
- StoreKit-2-Kauflogik
- kostenlose Basisversion und Pro-Freischaltung definieren
- frischer Installations-Test auf einem zweiten Mac
- TestFlight-Test
- Langzeittest mit großem synthetischem Dokumentbestand
- Developer-ID-/App-Store-Signierung
- Notarisierung beziehungsweise App-Store-Upload
- Lizenzhinweise für alle eingebundenen Komponenten und Modelle
- vollständige visuelle Abnahme in Deutsch und Englisch

---

# Version 1.1 – Stabilität und Suchqualität

- Suchranking weiter kalibrieren
- bessere Trefferbegründungen
- Antwortdarstellung weiter verbessern
- Quellenkarten und Seitenvorschau optimieren
- OCR-Schwellen mit größerem Testbestand kalibrieren
- Performance auf 8-GB-Macs optimieren
- Speicher- und Swap-Verhalten verbessern
- Wartungslisten weiter vereinfachen
- Diagnoseexport ohne private Inhalte
- bessere Wiederaufnahme nach App-Abbruch oder Neustart

---

# Version 1.2 – Bibliotheken und Organisation

- mehrere getrennte Dokumentbibliotheken
- Bibliothek wechseln, pausieren und archivieren
- Tags und benutzerdefinierte Metadaten
- gespeicherte Suchen
- Favoriten
- intelligente Sammlungen
- Import- und Exportfunktionen
- Backup und Wiederherstellung der lokalen Datenbank
- gezielter Neuaufbau einzelner Bibliotheken

---

# Version 1.5 – Erweiterte lokale KI

- weitere geprüfte Antwortmodelle
- weitere geprüfte Embedding-Modelle
- bessere Modellwahl nach verfügbarem RAM
- lokale Modellbenchmarks
- strukturierte Dokumentzusammenfassungen
- Extraktion von Personen, Daten, Beträgen und Aktenzeichen
- Tabellen- und Rechnungsanalyse
- dokumentübergreifende Vergleiche
- optional bestätigtes lokales Wissensgedächtnis mit Quellen

---

# Version 2.0 – Neue Produktgeneration

Mögliche größere Funktionen:

- iPhone- und iPad-Begleit-App
- Windows-Version
- lokale Netzwerkbibliotheken
- Team- und Mehrplatzfunktionen
- Rechte- und Rollenmodell
- E-Mail-Import
- Scanner-Import
- automatische Dokumentklassifikation
- regelbasierte Dokumentenworkflows
- lokale Agenten für wiederkehrende Aufgaben
- Synchronisation mehrerer Geräte
- optionales Abo-Modell für Version 2 und fortlaufende neue Funktionen

Die endgültige Geschäftsmodellentscheidung für Version 2.0 wird erst nach Erfahrungen mit Version 1.x getroffen.

---

# Aktuelle nächste sinnvolle Aufgabe

Die Version 1.0 auf eine verkaufsfähige Veröffentlichung vorbereiten:

1. App-Icon und Markenauftritt
2. Onboarding
3. Free-/Pro-Abgrenzung
4. StoreKit-2-Architektur
5. TestFlight-Vorbereitung
6. vollständiger Praxistest auf Mac mini und MacBook

---

# Offene Grundsatzentscheidungen

- endgültiger Verkaufspreis der Version 1
- Umfang der kostenlosen Basisversion
- Name und Inhalt der Pro-Version
- späteres Upgrade- oder Abo-Modell für Version 2
- direkter Vertrieb zusätzlich zum Mac App Store
- Umfang einer späteren Windows-Version
