#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${1:-release}
bundle_path="$project_root/build/Findora.app"
derived_data="$project_root/.build/findora-xcode-derived-data"

cd "$project_root"

case "${configuration:l}" in
  debug)
    xcode_configuration=Debug
    ;;
  release)
    xcode_configuration=Release
    ;;
  *)
    print -u2 "Unbekannte Konfiguration: $configuration (erlaubt: debug, release)"
    exit 2
    ;;
esac

# MLX liefert Metal-Shader mit. Nur Xcode kompiliert sie zu default.metallib;
# ein reiner `swift build`-Build ist deshalb kein lauffähiges App-Artefakt.
xcodebuild \
  -quiet \
  -scheme Findora \
  -configuration "$xcode_configuration" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  build

binary_directory="$derived_data/Build/Products/$xcode_configuration"
binary_path="$binary_directory/Findora"
if [[ ! -x "$binary_path" ]]; then
  print -u2 "Xcode-Produkt fehlt: $binary_path"
  exit 1
fi

if [[ "$bundle_path" != "$project_root/build/Findora.app" ]]; then
  print -u2 "Unsicherer Bundle-Pfad: $bundle_path"
  exit 1
fi

rm -rf "$bundle_path"
mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_path" "$bundle_path/Contents/MacOS/Findora"
cp "$project_root/Config/Info.plist" "$bundle_path/Contents/Info.plist"

for resource_bundle in "$binary_directory"/*.bundle(N); do
  ditto "$resource_bundle" "$bundle_path/Contents/Resources/${resource_bundle:t}"
done

app_resource_bundle="$binary_directory/Findora_PrivateDocSearchApp.bundle/Contents/Resources"
if [[ ! -d "$app_resource_bundle" ]]; then
  print -u2 "Findora-Ressourcenbundle fehlt: $app_resource_bundle"
  exit 1
fi
for localization in "$app_resource_bundle"/*.lproj(N); do
  ditto "$localization" "$bundle_path/Contents/Resources/${localization:t}"
done

if [[ ! -f "$bundle_path/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  print -u2 "MLX-Metal-Bibliothek fehlt im App-Bundle."
  exit 1
fi

codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$project_root/Config/PrivateDocSearch.entitlements" \
  "$bundle_path"

print "$bundle_path"
