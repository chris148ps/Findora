# Dynamisches Modellrouting

Stand: 30. Juli 2026

## Katalog

Der gebündelte Katalog besitzt Schema 2 und kann nur durch ein App-Update
ersetzt werden. Jeder Eintrag pinnt Repository-Revision, Einzeldateien,
Größen, SHA-256, Runtime, Fähigkeiten, RAM-Grenzen, Lizenz und
experimentellen Status.

| Rolle | Modell | Runtime | Download | Runtime-RAM |
| --- | --- | --- | ---: | ---: |
| Hauptmodell | Qwen 3.5 4B MLX 4 Bit | `mlx_text` | 3.061.129.077 B | 4.831.838.208 B |
| Prüfer | Phi-4 Mini Instruct 4 Bit | `mlx_text` | 2.179.993.199 B | 3.758.096.384 B |
| visuell, experimentell | Gemma 4 E2B Instruct 4 Bit | `mlx_vision` | 3.583.086.498 B | 6.442.450.944 B |

Alte Qwen-Modelle bleiben sichtbar und werden nicht automatisch gelöscht.

## Auswahl und Download

`ModelRouter` filtert nach Fähigkeit, Hardware, Installation, Fehlerstatus,
Nutzerpräferenz, experimentellem Status und Speicherdruck. Qwen 3.5 wird für
Extraktion, Beziehungen, Zusammenfassung und Antworten bevorzugt. Phi wird für
Wissens- und Widerspruchsprüfung bevorzugt. Gemma wird nur für optische
Aufgaben betrachtet und bleibt standardmäßig experimentell.

Fehlt ein Modell, liefert das Routing einen Downloadbedarf. Der bestehende
Downloadmanager zeigt Zweck, Größe, RAM und Lizenz, unterstützt
Pause/Fortsetzung, prüft jede Datei und schließt atomar ab. Automatische
empfohlene Downloads sind standardmäßig aus.

Ist die lokale Opt-in-Einstellung aktiviert, verwendet die App diese
Routingentscheidung produktiv: Qwen 3.5 und danach Phi-4 Mini werden aus dem
festen Katalog installiert und aktiviert. Ohne Opt-in bleibt der Job
`waiting_for_model`; es findet kein Hintergrunddownload statt.

## 8-GB-Schutz

`ModelMemoryBudget` reserviert Runtime-RAM abzüglich Systemreserve. Bis 8 GiB
wird Kontext zunächst auf 2.048 Token, bei Warn-Speicherdruck auf 1.024
begrenzt. Kritischer Druck blockiert neue Leases.

`ModelLeaseManager` vergibt genau eine aktive generative Lease. Vor einem
Wechsel wird die alte Runtime entladen und erst dann die neue geladen. Die
Warteschlange ist priorisiert, abbruchfähig, timeoutbegrenzt und verwendet nach
Ladefehlern einen Cooldown. Diagnoselogs enthalten keine Dokumentinhalte.

Für die tatsächlich aufgerufenen MLX-Generatoren serialisiert zusätzlich ein
prozessweiter `LocalGenerativeTaskGate` Wissensjobs, Suchplanung, Antworten
und optische Analyse. Die Extraktionskoordination entlädt Qwen vor der
unabhängigen Phi-Prüfung.
