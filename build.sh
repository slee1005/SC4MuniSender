#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_output="${1:-$task_root/dist/SC4 Muni Sender.app}"
task_cache="${TMPDIR:-/tmp}/sc4-muni-sender-swift-cache"
mkdir -p "$task_output/Contents/MacOS" "$task_output/Contents/Resources" "$task_cache"
swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$task_cache" \
  -framework SwiftUI -framework AppKit -framework Network \
  "$task_root"/Sources/*.swift \
  -o "$task_output/Contents/MacOS/SC4MuniSender"
cp "$task_root/Info.plist" "$task_output/Contents/Info.plist"
codesign --force --sign - "$task_output"
codesign --verify --verbose "$task_output"
printf '%s\n' "$task_output"
