# Sicherheit

## Schutzgrenzen

Findora schützt private Dokumente und E-Mails vor unbeabsichtigter externer
Übertragung und vor unsicheren OCR-Ersetzungen. Die App ist kein
Mehrbenutzersystem und verschlüsselt den lokalen Index in Version 1 nicht.
macOS-Dateirechte und FileVault bleiben die maßgeblichen Schutzmechanismen für
Daten im Benutzerkonto.

## Dateizugriff

Der Nutzer wählt den Stammordner über `NSOpenPanel`. Ein Security-Scoped
Bookmark persistiert die Freigabe. Die App folgt keinen Symlinks und schließt
eigene Arbeits-, Modell- und temporäre Dateien vom Scan aus. Ein nicht
erreichbarer Stammordner wird nicht als Löschung aller Dokumente gewertet.

Die interne Homebrew-OCR-Version wird ohne App Sandbox signiert, weil eine
sandboxed App externe Homebrew-Programme nicht zuverlässig ausführen kann.
Die kleinsten vorgesehenen Sandbox-Entitlements liegen separat in
`Config/Findora-Sandbox.entitlements`; sie sind für eine spätere
Version mit gebündeltem OCR-Helfer bestimmt.

Mailquellen werden ausschließlich über `NSOpenPanel` hinzugefügt. Beim Start
werden weder Mailprogramme gesucht noch interne Maildatenbanken geöffnet.
MBOX/EML/MSG werden nicht verändert. Importfehlerprotokolle enthalten
Kategorien, aber weder Betreff noch Absender, Text oder Anhangsnamen.

Ein verschiebbarer Datenspeicher darf nicht auf einem erkannten Netzwerk-,
Cloud-, schreibgeschützten oder ungeeigneten Dateisystemziel liegen. Die
Umschaltung erfolgt erst nach Kopie, SHA-256-Prüfung und SQLite-`quick_check`.

## Sichere OCR-Ersetzung

OCR arbeitet auf einer eindeutig benannten temporären Datei im selben Ordner.
Vor dem atomaren Austausch werden PDF-Signatur, Lesbarkeit, Seitenzahl,
Textschicht und unveränderter Eingangshash geprüft. Die App löscht das
Original nicht vorab. Fehler vor dem Austausch lassen das Original
unverändert.

## Modelle und Lieferkette

- Katalogeinträge pinnen Anbieter, Revision, Dateiliste, Größe und SHA-256.
- Downloads verwenden HTTPS und eine Host-Allowlist.
- Alle Modelldateien werden vor der Installation validiert.
- Neue Versionen ersetzen eine funktionierende alte Version erst nach Prüfung.
- Beliebige Modell-URLs aus Nutzereingaben werden nicht unterstützt.
- Modelllizenzen werden in der UI angezeigt.
- Das optische Dokumentmodell wird nur nach ausdrücklichem Download aktiviert,
  ausschließlich lokal ausgeführt und erhält jeweils nur eine gerenderte
  Problemseite. Es kann keine Dateioperation auslösen oder manuelle
  Bewertungen überschreiben.

Swift-Paketversionen sind in `Package.resolved` festgehalten. Vor einer
externen Distribution sind zusätzlich SBOM, Signierung, Notarisierung und
Abhängigkeitsaudit erforderlich.

## Prompt Injection und Quellen

PDF- und E-Mail-Text sind nicht vertrauenswürdige Eingaben. Das Systemprompt weist das lokale
Sprachmodell an, Anweisungen in Dokumenten nicht auszuführen. Die App vergibt
opaque Quellen-IDs und löst Dateiname sowie Seitenzahl erst nach der
Generierung aus der Datenbank auf. Vom Modell erfundene IDs werden verworfen.

## Logs

Dokumenttext, Embeddings, Suchauszüge, vollständige Prompts und Antworten
gehören nicht in Logs. Zulässig sind Dateiname, Pfad, Status, Dauer und
technische Fehler. Für weitergegebene Logs sollten sensible Pfadteile
geschwärzt werden.

Automatische Crashberichte sind die einzige ausdrücklich freigegebene
Ausnahme von der sonst vollständig lokalen Verarbeitung. Sie sind
standardmäßig aktiviert und in den Einstellungen jederzeit abschaltbar. Vor
der Übergabe an Apple Mail werden Home-Verzeichnisse, absolute Pfade,
E-Mail-Adressen sowie `path=`-Logfelder geschwärzt; Dokumentinhalte,
Suchanfragen, OCR-Texte und Dateinamen werden nicht aufgenommen. Der Bericht
wird ausschließlich an die fest im Build konfigurierte, syntaktisch
validierte Findora-Supportadresse gesendet. Findora prüft oder startet Apple
Mail nur, wenn ein ausstehender Bericht, die Aktivierung und eine gültige
Supportadresse gleichzeitig vorliegen.

## Bekannte Grenzen

- Der SQLite-Index ist nicht anwendungsseitig verschlüsselt.
- Die interne App ist ad-hoc signiert und nicht notarisiert.
- Homebrew-OCR vergrößert die lokale Lieferkette.
- Ein Benutzerprozess mit denselben macOS-Rechten kann auf Index und Modelle
  zugreifen.

Sicherheitsprobleme sollten mit reproduzierbaren Schritten gemeldet werden,
jedoch ohne private PDF-Inhalte oder ungeschwärzte Pfade anzuhängen.
