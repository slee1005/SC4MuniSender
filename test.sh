#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_cache="${TMPDIR:-/tmp}/sc4-muni-sender-swift-cache"
task_binary="$task_root/.build/ReplayTests"
mkdir -p "$task_root/.build" "$task_cache"
swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$task_cache" -framework Network \
  "$task_root/Sources/ReplayData.swift" "$task_root/Sources/OpenConnectTransport.swift" \
  "$task_root/Sources/ShotImport.swift" \
  "$task_root/Sources/PuttingShotMaker.swift" \
  "$task_root/Sources/LaunchAngleAdjustments.swift" \
  "$task_root/Sources/DeletedShots.swift" \
  "$task_root/Tests/ReplayTests.swift" -o "$task_binary"
"$task_binary" "$@"
