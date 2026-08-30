#!/bin/bash
#
# Deadeye. Copyright (C) 2026 inulute.
# Licensed under the GNU General Public License v3.0. See LICENSE.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)/wine-detection-test"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

swiftc -swift-version 5 \
	-o "$OUT" \
	"$HERE/Sources/Deadeye/Wine.swift" \
	"$HERE/Sources/Deadeye/CursorGuard.swift" \
	"$HERE/Sources/Deadeye/MenuBarGeometry.swift" \
	"$HERE/Sources/Deadeye/Log.swift" \
	"$HERE/Sources/Deadeye/Stats.swift" \
	"$HERE/Tests/main.swift"

"$OUT"
