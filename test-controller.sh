#!/bin/zsh
set -euo pipefail
controller_root="${0:A:h}"
controller_cache="${TMPDIR:-/tmp}/muni-controller-swift-cache"
mkdir -p "$controller_root/.build" "$controller_cache"
swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$controller_cache" \
  -framework SwiftUI -framework AppKit -framework Network \
  "$controller_root/Sources/ReplayData.swift" "$controller_root/Sources/OpenConnectTransport.swift" \
  "$controller_root/Controller/Sources/ControllerCore.swift" "$controller_root/Controller/Sources/TimingCore.swift" \
  "$controller_root/Controller/Sources/ControllerModel.swift" \
  "$controller_root"/Controller/Tests/*.swift -o "$controller_root/.build/ControllerTests"
"$controller_root/.build/ControllerTests" "$@"
