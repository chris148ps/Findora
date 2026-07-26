#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
plist="$project_root/Config/Info.plist"
source_file="$project_root/Sources/PrivateDocSearchApp/PrivateDocSearchApp.swift"
english_file="$project_root/Sources/PrivateDocSearchApp/Resources/en.lproj/Localizable.strings"

assert_equal() {
  local actual=$1
  local expected=$2
  local label=$3
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "$label: erwartet '$expected', gefunden '$actual'"
    exit 1
  fi
}

assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" "Findora" "CFBundleExecutable"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" "Findora" "CFBundleDisplayName"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" "Findora" "CFBundleName"
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" "de.privatedocsearch.app" "CFBundleIdentifier"

rg -q 'name: "Findora"' "$project_root/Package.swift"
rg -q 'build/Findora\.app' "$project_root/scripts/build-app.sh"
rg -q 'Contents/MacOS/Findora' "$project_root/scripts/build-app.sh"
rg -q 'Findora_PrivateDocSearchApp\.bundle' "$project_root/scripts/build-app.sh"
rg -q 'appending\(path: "PrivateDocSearch"' "$project_root/Sources/PrivateDocSearchCore/AppPaths.swift"
rg -q 'appending\(path: "PrivateDocSearch\.sqlite3"' "$project_root/Sources/PrivateDocSearchCore/AppPaths.swift"

if rg -n '"PrivateDocSearch:?"' "$source_file" "$english_file"; then
  print -u2 "Alter Produktname ist noch als sichtbarer UI-Text vorhanden."
  exit 1
fi

print "Produktnamen- und Kompatibilitätsprüfung bestanden."
