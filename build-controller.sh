#!/bin/zsh
set -euo pipefail
controller_root="${0:A:h}"
controller_output="${1:-$controller_root/dist/Muni Controller.app}"
controller_cache="${TMPDIR:-/tmp}/muni-controller-swift-cache"
mkdir -p "$controller_output/Contents/MacOS" "$controller_output/Contents/Resources" "$controller_cache"
swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$controller_cache" \
  -framework SwiftUI -framework AppKit -framework Network \
  "$controller_root/Sources/ReplayData.swift" "$controller_root/Sources/OpenConnectTransport.swift" \
  "$controller_root"/Controller/Sources/*.swift -o "$controller_output/Contents/MacOS/MuniController"
cp "$controller_root/Controller/Info.plist" "$controller_output/Contents/Info.plist"
cp "$controller_root/Controller/README.md" "$controller_output/Contents/Resources/사용법.md"
codesign --force --sign - "$controller_output"
codesign --verify --deep --strict "$controller_output"
printf '%s\n' "$controller_output"
