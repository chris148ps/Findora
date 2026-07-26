#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
marker_path=/private/tmp/Findora-run-mlx-tests
derived_data=/private/tmp/FindoraDerivedData

cleanup() {
  rm -f "$marker_path"
}
trap cleanup EXIT INT TERM

touch "$marker_path"
cd "$project_root"
xcodebuild \
  -quiet \
  -scheme Findora-Package \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  test
