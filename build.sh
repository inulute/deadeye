#!/bin/bash
#
# Deadeye. Copyright (C) 2026 inulute.
# Licensed under the GNU General Public License v3.0. See LICENSE.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Deadeye"

VERSION="0.0.0-dev"
DO_INSTALL=0
while [ $# -gt 0 ]; do
	case "$1" in
		--install) DO_INSTALL=1 ;;
		--version) shift; VERSION="${1:-}" ;;
		--version=*) VERSION="${1#*=}" ;;
		*) echo "usage: $0 [--install] [--version X.Y.Z]" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$VERSION" ] || { echo "error: --version needs a value" >&2; exit 2; }
APP="$HERE/$APP_NAME.app"
SRC_DIR="$HERE/Sources/Deadeye"
BIN_NAME="Deadeye"

[ -f "$SRC_DIR/main.swift" ] || { echo "error: $SRC_DIR/main.swift missing" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "error: swiftc not found; run xcode-select --install" >&2; exit 1; }

if pgrep -x "$BIN_NAME" >/dev/null 2>&1; then
	echo "Quitting running instance…"
	pkill -TERM -x "$BIN_NAME" || true
	sleep 1.5
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -swift-version 5 -O \
	-target "arm64-apple-macosx13.0" \
	-framework AppKit \
	-framework Carbon \
	-o "$APP/Contents/MacOS/$BIN_NAME" \
	"$SRC_DIR"/*.swift

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.deadeye.Deadeye</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>$BIN_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

if [ -f "$HERE/assets/Deadeye.icns" ]; then
	cp "$HERE/assets/Deadeye.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "warning: assets/Deadeye.icns missing — app will have no icon" >&2
fi

SIGN_ID=""
if [ -n "${SIGN_IDENTITY:-}" ] \
   && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
	SIGN_ID="$SIGN_IDENTITY"
fi
[ -n "$SIGN_ID" ] || for candidate in "Deadeye Local Signing" "mac-gaimgfix Local Signing"; do
	if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$candidate"; then
		SIGN_ID="$candidate"; break
	fi
done
if [ -n "$SIGN_ID" ]; then
	codesign --force --options runtime --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1 \
		&& echo "Signed with: $SIGN_ID (hardened runtime)" \
		|| { echo "warning: signing with '$SIGN_ID' failed; falling back to ad-hoc" >&2
		     codesign --force --options runtime --sign - "$APP" >/dev/null 2>&1 || true; }
else
	echo "note: no local signing identity — using ad-hoc, so Accessibility must be"
	echo "      re-granted after each rebuild. Fix with ./create-signing-identity.sh"
	codesign --force --options runtime --sign - "$APP" >/dev/null 2>&1 || true
fi
touch "$APP"

echo "Built: $APP (version $VERSION)"

if [ "$DO_INSTALL" = "1" ]; then
	DEST="/Applications/$APP_NAME.app"
	rm -rf "$DEST"
	cp -R "$APP" "$DEST"
	xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
	rm -rf "$APP"
	echo "Installed: $DEST (build copy removed to keep one bundle identity)"
	( open "$DEST" >/dev/null 2>&1 & )
	echo "Launched from /Applications. Look for the Deadeye eye icon in your menu bar."
else
	echo "Open it, then look for the Deadeye eye icon in your menu bar."
fi
