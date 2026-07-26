# Oberfläche, Lokalisierung und Erscheinungsbild

## Sprache

Die SwiftUI-Oberfläche verwendet lokalisierbare Schlüssel. Deutsch ist die
Quellsprache und bleibt für bestehende Installationen ohne gespeicherte Wahl
aktiv. `en.lproj/Localizable.strings` enthält die englische Übersetzung.
Auswählbar sind Deutsch, Englisch und Systemsprache; nicht unterstützte
Systemsprachen fallen auf Englisch zurück. Die Wahl wird als
`interfaceLanguage` in SQLite gespeichert.

Die Locale wird am Hauptfenster, am Menüleistenfenster und an den Einstellungen
gesetzt. Dynamische Dateinamen, Pfade und technische IDs werden nicht
übersetzt. Dokumentinhalte werden durch die Lokalisierung weder gelesen noch
verändert.

## Erscheinungsbild

`interfaceAppearance` speichert System, Hell oder Dunkel. SwiftUI erhält den
entsprechenden bevorzugten Farbstil auf allen App-Szenen. Semantische Farben
und Materialien sorgen dafür, dass Trefferkarten, Wartungslisten, Dialoge,
Sheets und Markdown-Antworten in beiden Modi lesbar bleiben. Eine Änderung wird
nach dem Speichern unmittelbar sichtbar und beim Neustart rekonstruiert.

## Fortschritt und Live-Aktualisierung

`processing_sessions` ist die stabile Quelle für laufende, pausierte,
abgeschlossene und fehlgeschlagene Verarbeitung. Erfolgreiche
SQLite-Transaktionen senden gezielte Statusereignisse, die UI bündelt diese auf
ungefähr 300 ms. Der 30-Sekunden-Abgleich ist nur ein Sicherheitsnetz. Ein
Abschluss bleibt sechs Sekunden sichtbar; ein Neustart rekonstruiert laufende
oder pausierte Sitzungen.

Die technischen Statuskarten verwenden eindeutige Einheiten und lokalisierte
Hilfetexte. Die vier Hauptkennzahlen bleiben unverändert; Dokumente,
Texterkennung, Suche/Index und Wartung sind getrennte Gruppen.

Beim Erzeugen des Release-Bundles kopiert `scripts/build-app.sh` die
`.lproj`-Verzeichnisse zusätzlich aus dem Swift-Package-Ressourcenbundle in
`Contents/Resources`. Dadurch kann SwiftUI die gewählte Sprache auch im
fertigen App-Hauptbundle auflösen; Deutsch bleibt die Entwicklungssprache.
