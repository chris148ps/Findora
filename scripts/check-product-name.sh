#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
plist="$project_root/Config/Info.plist"

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
assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" "de.findora.app" "CFBundleIdentifier"

rg -q 'name: "Findora"' "$project_root/Package.swift"
rg -q 'name: "FindoraCore"' "$project_root/Package.swift"
rg -q 'name: "FindoraMLX"' "$project_root/Package.swift"
rg -q 'name: "FindoraApp"' "$project_root/Package.swift"
rg -q 'name: "FindoraCoreTests"' "$project_root/Package.swift"
rg -q 'build/Findora\.app' "$project_root/scripts/build-app.sh"
rg -q 'Contents/MacOS/Findora' "$project_root/scripts/build-app.sh"
rg -q 'Findora_FindoraApp\.bundle' "$project_root/scripts/build-app.sh"
rg -q 'appending\(path: "Findora"' "$project_root/Sources/FindoraCore/AppPaths.swift"
rg -q 'appending\(path: "Findora\.sqlite3"' "$project_root/Sources/FindoraCore/AppPaths.swift"
rg -q 'appending\(path: "Findora\.log"' "$project_root/Sources/FindoraCore/AppFileLogger.swift"
rg -q '"FINDORA_DISABLE_DOCUMENT_ACCESS"' "$project_root/Sources/FindoraApp/FindoraApp.swift"
rg -q 'findora://source/' "$project_root/Sources/FindoraApp/FindoraApp.swift"

for required_path in \
    "$project_root/Sources/FindoraApp/FindoraApp.swift" \
    "$project_root/Sources/FindoraCore" \
    "$project_root/Sources/FindoraMLX" \
    "$project_root/Tests/FindoraCoreTests" \
    "$project_root/Config/Findora.entitlements" \
    "$project_root/Config/Findora-Sandbox.entitlements"; do
  if [[ ! -e "$required_path" ]]; then
    print -u2 "Findora-Pfad fehlt: $required_path"
    exit 1
  fi
done

legacy_name='Private''DocSearch'
legacy_name_lower='private''docsearch'
if rg -n -i "$legacy_name|$legacy_name_lower" \
    --glob '!.build/**' \
    --glob '!build/**' \
    --glob '!Package.resolved' \
    "$project_root"; then
  print -u2 "Technischer Altname ist noch im Repository vorhanden."
  exit 1
fi

print "Vollständige Findora-Namensprüfung bestanden."
