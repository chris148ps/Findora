#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
source_file="$project_root/Sources/PrivateDocSearchApp/PrivateDocSearchApp.swift"
english_file="$project_root/Sources/PrivateDocSearchApp/Resources/en.lproj/Localizable.strings"
audit_directory=$(mktemp -d /tmp/PrivateDocSearch-localization.XXXXXX)
trap 'rm -rf "$audit_directory"' EXIT

plutil -lint "$english_file"
plutil -convert json -o "$audit_directory/english.json" "$english_file"
jq -r 'keys[]' "$audit_directory/english.json" \
  | sort > "$audit_directory/english.keys"

rg -o \
  'Text\("[^"\\]*(?:\\.[^"\\]*)*"|Button\("[^"\\]*(?:\\.[^"\\]*)*"|Label\("[^"\\]*(?:\\.[^"\\]*)*"|Section\("[^"\\]*(?:\\.[^"\\]*)*"|navigationTitle\("[^"\\]*(?:\\.[^"\\]*)*"|Picker\("[^"\\]*(?:\\.[^"\\]*)*"|Toggle\("[^"\\]*(?:\\.[^"\\]*)*"|ContentUnavailableView\("[^"\\]*(?:\\.[^"\\]*)*"|GroupBox\("[^"\\]*(?:\\.[^"\\]*)*"|confirmationDialog\("[^"\\]*(?:\\.[^"\\]*)*"|alert\("[^"\\]*(?:\\.[^"\\]*)*"' \
  "$source_file" \
  | sed -E 's/^[^(]+\("//; s/"$//' \
  | rg -v '\\\(' \
  | sort -u > "$audit_directory/static-ui.keys"

missing=$(comm -23 \
  "$audit_directory/static-ui.keys" \
  "$audit_directory/english.keys")
if [[ -n "$missing" ]]; then
  print -u2 "Fehlende englische UI-Schlüssel:"
  print -u2 "$missing"
  exit 1
fi

print "Lokalisierungsprüfung bestanden."
