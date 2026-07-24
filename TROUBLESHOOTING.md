# Fehlerbehebung

## „Metal Toolchain fehlt“

```bash
xcodebuild -showComponent MetalToolchain -json
xcodebuild -downloadComponent MetalToolchain
```

MLX darf für einen produktiven App-Build nicht nur mit `swift build` gebaut
werden, weil dabei die Metal-Shader nicht zu `default.metallib` kompiliert
werden.

## OCRmyPDF oder Hilfsprogramme fehlen

```bash
brew install ocrmypdf tesseract-lang poppler
ocrmypdf --version
tesseract --list-langs
pdftotext -v
pdfinfo -v
```

Auf Apple Silicon erwartet die App die Programme üblicherweise unter
`/opt/homebrew/bin`. Ein abweichender OCRmyPDF-Pfad kann in den Einstellungen
geprüft werden.

## Sprache `deu` oder `eng` fehlt

`brew install tesseract-lang` ausführen und die App neu starten. Unter **OCR**
nur tatsächlich installierte Sprachen auswählen.

## Ordner ist nicht erreichbar

- Externes oder Netzwerk-Volume erneut verbinden.
- Unter **Einstellungen** denselben Stammordner erneut auswählen.
- macOS-Datenschutzfreigaben für die App kontrollieren.

PrivateDocSearch löscht bei einem unerreichbaren Stammordner keine
Indexeinträge. Cloud-Platzhalter müssen lokal geladen sein, bevor OCR und
Indexierung sie verarbeiten können.

## Eine PDF bleibt in der Warteschlange

Die Datei kann noch kopiert werden, gesperrt sein oder sich zwischen zwei
Stabilitätsprüfungen ändern. Nach Abschluss des Kopiervorgangs erneut scannen.
Unter **Logs** steht der technische Grund. Bei einem dauerhaften Fehler
**Fehler erneut einplanen** verwenden.

## OCR ist fehlgeschlagen

Das Original bleibt bei einem Fehler vor dem atomaren Austausch unverändert.
Prüfen:

- ist die PDF mit Vorschau/PDFKit lesbar;
- ist ausreichend freier Speicher auf demselben Volume vorhanden;
- liefert `pdfinfo datei.pdf` einen Fehler;
- sind die gewählten Tesseract-Sprachen installiert.

Keine temporären Dateien pauschal löschen. App-eigene OCR-Reste werden anhand
ihres eindeutigen Präfixes verwaltet.

## Modell kann nicht installiert werden

- Internetzugang und freien SSD-Speicher prüfen.
- Download fortsetzen statt neu starten.
- Bei Prüfsummenfehler abbrechen; die Datei wird nicht aktiviert.
- Nicht kompatible Modelle sind wegen des RAM-Budgets gesperrt.

## Suche liefert keine Antwort

Prüfen, ob die Erstindexierung abgeschlossen und ein Embedding-Modell aktiv
ist. Für eine formulierte Antwort muss außerdem ein kompatibles lokales
Antwortmodell installiert und aktiv sein. Bei zu schwachen Fundstellen ist
„keine ausreichenden Belege“ beabsichtigtes Verhalten.

## App startet, aber MLX meldet `default.metallib`

Die App wurde wahrscheinlich mit dem SwiftPM-CLI-Pfad gebaut. Metal-Toolchain
installieren und `./scripts/build-app.sh` erneut ausführen. Das App-Bundle muss
das von Xcode erzeugte MLX-Ressourcenbundle enthalten.

## Vollständig zurücksetzen

App beenden und nur nach bewusstem Entschluss diese lokalen App-Daten
entfernen:

```text
~/Library/Application Support/PrivateDocSearch/
~/Library/Logs/PrivateDocSearch/
```

Die ausgewählten Original-PDFs liegen nicht dort und dürfen nicht gelöscht
werden.

## Technisches Protokoll

Memory-Pressure-Ereignisse, Pausierung/Fortsetzung, Modell-Entladung und
technische Fehler stehen zeilenweise unter:

```text
~/Library/Logs/PrivateDocSearch/PrivateDocSearch.log
```

Dokumentinhalte werden dort nicht protokolliert.
