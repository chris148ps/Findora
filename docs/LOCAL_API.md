# Lokale API-Architektur

Stand: 30. Juli 2026

## Ziel

`LocalKnowledgeAPI` ist die transportneutrale, lokale Grenze für spätere MCP-,
REST-, Apple-Shortcuts-, Apple-Intelligence- und Plugin-Adapter. Die aktuelle
Implementierung öffnet keinen Netzwerkport, startet keinen Server und
überträgt keine Inhalte.

## Implementierte Operationen

- Wissens-, Ontologie-, Agenten- und Auditstatus lesen;
- begrenzte Prüfsnapshots laden;
- einen begrenzten Wissensgraphen ab einer Entität lesen;
- aktive Ontologietypen lesen;
- eine idempotente vollständige Wissensneuanalyse einreihen.

Die Implementierung `FindoraLocalKnowledgeAPI` delegiert an
`SQLiteDatabase`. Sie akzeptiert weder SQL noch freie Modellprompts oder
Dateipfade.

## Adapterregeln

Ein späterer Adapter muss:

1. standardmäßig deaktiviert sein;
2. ausschließlich an Loopback oder einen ausdrücklich freigegebenen lokalen
   Dienst binden;
3. Authentisierung, Capability-Freigaben und begrenzte Ergebnisse erzwingen;
4. keine Dokumentinhalte oder Suchanfragen extern übertragen;
5. jede Mutation über dieselben Audit- und Revisionspfade führen;
6. niemals Originaldokumente ändern.

Ein Adapter ist erst produktiv, wenn Bedrohungsmodell, Berechtigungsdialog,
Rate Limits, Tests und UI-Abschaltung separat abgenommen sind.
