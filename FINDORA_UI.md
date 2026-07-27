# Findora – UI und technische Produktidentität

## Produktname

Der sichtbare Produktname lautet **Findora**. Er wird im Hauptfenster, in der
Menüleiste, im Über-Fenster, in Antworten sowie in den App-Metadaten verwendet.
Der Release-Build erzeugt `build/Findora.app` mit dem Executable `Findora`.

Swift-Module, Quellverzeichnisse, Bundle-ID und lokale Speicherorte verwenden
durchgängig den Produktnamen:

```text
Bundle-ID: de.findora.app
~/Library/Application Support/Findora/
~/Library/Logs/Findora/
```

Die Datenbank heißt `Findora.sqlite3`, das technische Protokoll `Findora.log`.
Da es noch keine produktiven Installationen gibt, wird keine Altpfad- oder
Einstellungsmigration ausgeführt.

`UserDefaults.standard` verwendet über die neue Bundle-ID die Findora-
Preferences-Domain. Dedizierte Cache-Verzeichnisse, Spotlight-Importer,
QuickLook-Erweiterungen, Xcode-Projekte/-Workspaces, CI-Konfigurationen,
Release-Skripte sowie App-Icon- oder Launch-Asset-Kataloge sind in diesem
SwiftPM-Projekt nicht vorhanden; der Audit ergab deshalb dort keine
umzubenennenden oder doppelten Artefakte.

## Navigation

Die linke Seitenleiste ist in vier Arbeitsgruppen gegliedert:

1. Suche
2. Dokumentenstatus und Dokumentenwartung
3. OCR und Modelle
4. Einstellungen und Logs

Sie ist zwischen 245 und 280 Punkten breit, mit einer Idealbreite von
255 Punkten. Zeilen sind mindestens 34 Punkte hoch und verwenden
systemeigene Symbole, Abstände, Auswahlfarben und
Barrierefreiheitsbeschriftungen.

## Dokumentenwartung

Die Wartungsbereiche werden als horizontal scrollbare Schaltflächen angezeigt.
Suche, Sortierung, Statusfilter und Aktualisieren stehen darunter. Bei schmalen
Fenstern wechseln Filter und Aktionsleisten in eine mehrzeilige Anordnung,
statt Texte oder Schaltflächen abzuschneiden.

Auswahlaktionen stehen direkt oberhalb der Liste. Destruktive Aktionen befinden
sich in einer dauerhaft getrennten unteren Aktionsleiste und bleiben rot
gekennzeichnet. OCR-Sammelaktionen sind in einem Menü gebündelt.

Leere Ansichten erklären jeweils den Zustand und bieten **Erneut prüfen** an:

- keine Duplikate
- keine leeren Seiten
- keine OCR-Prüffälle
- keine leeren PDFs
- keine fehlenden Dateien

Die Leerseitenanalyse lässt sich weiterhin für einzelne Seiten über
**Analyse neu starten** zurücksetzen und erneut ausführen.

## Fenstergrößen und Erscheinungsbild

Das Hauptfenster hat eine Mindestgröße von 1050 × 700 Punkten. Die
NavigationSplitView-, List-, Form-, Toolbar- und ContentUnavailableView-
Komponenten stammen aus SwiftUI und folgen System-, Hell- und Dunkelmodus.
Wartungsfilter und Aktionsleisten verwenden `ViewThatFits`, sodass normale und
kompakte Breiten dieselben Funktionen ohne horizontales Abschneiden anbieten.

## Lokalisierung

Deutsch ist die Entwicklungssprache. Alle neuen sichtbaren Texte besitzen eine
englische Übersetzung in `en.lproj/Localizable.strings`. Die automatisierte
Lokalisierungsprüfung muss vor einem Build ohne fehlende Schlüssel enden.

## Über-Fenster

**Über Findora** zeigt Produktname, Version, Build, lokale Verarbeitung und den
Hinweis, dass keine allgemeine Telemetrie verwendet wird. Die separat
aktivierbaren, bereinigten Crashberichte sind in den Einstellungen erklärt.
Das Über-Fenster verändert keine Dokumente und löst keine externen
Abhängigkeitsprüfungen aus.

## Kurzbeschreibungen

Deutsch:

> Findora durchsucht und analysiert private PDF-Dokumente lokal auf dem Mac.

English:

> Findora searches and analyzes private PDF documents locally on your Mac.

Vorgesehene Screenshot-Titel:

| Deutsch | English |
| --- | --- |
| Private Dokumente lokal durchsuchen | Search private documents locally |
| Dokumentenstatus live verfolgen | Track document status live |
| OCR lokal und austauschbar | Local, interchangeable OCR |
| Dokumente sicher warten | Maintain documents safely |

## Offener Punkt

**Marken- und Namensprüfung „Findora“ vor Veröffentlichung ausstehend.**
Dieser Umbau führt weder Tag noch Release oder App-Store-Veröffentlichung aus.
