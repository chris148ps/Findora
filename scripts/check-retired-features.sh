#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
app_source="$project_root/Sources/FindoraApp/FindoraApp.swift"
search_source="$project_root/Sources/FindoraCore/HybridSearchService.swift"
database_source="$project_root/Sources/FindoraCore/SQLiteDatabase.swift"

if rg -n \
    'case (partners|projects)|CommunicationPartnersView|CommunicationProjectsView|"Kommunikationspartner"|"Projekte"' \
    "$app_source"; then
  print -u2 "Zurückgestellte Partner-/Projektoberflächen sind noch aktiv."
  exit 1
fi

if rg -n 'graphRank|graphMatches|SearchMatchKind\\.relation' "$search_source"; then
  print -u2 "Partner-/Projektbeziehungen wirken noch in der aktiven Suche."
  exit 1
fi

if rg -n \
    'prepareIncrementalAnalysisUpgrades|runIncrementalAnalysisUpgradeBatch' \
    "$app_source" \
    || rg -n \
    'projectReferences\\(in: combined\\)|let sharedReferences' \
    "$database_source"; then
  print -u2 "Partner-/Projektanalysen werden noch automatisch vorbereitet oder erzeugt."
  exit 1
fi

print "Prüfung der zurückgestellten Partner-/Projektfunktionen bestanden."
