#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
marker_path=/private/tmp/PrivateDocSearch-run-mlx-tests
derived_data=/private/tmp/PrivateDocSearchDerivedData

cleanup() {
  rm -f "$marker_path"
}
trap cleanup EXIT INT TERM

touch "$marker_path"
cd "$project_root"
xcodebuild \
  -quiet \
  -scheme PrivateDocSearch-Package \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  test

