#!/bin/bash
#
# Deadeye. Copyright (C) 2026 inulute.
# Licensed under the GNU General Public License v3.0. See LICENSE.
#
# Builds "Deadeye.app" next to this script.
# Needs only the Command Line Tools — no full Xcode.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Deadeye"

# Version goes into CFBundleShortVersionString, which Updater.swift compares against
# the latest GitHub release. Hardcoding it is a trap: ship v1.1 with a binary that
# still says 1.0.0 and every user is told forever that an update is available. The
# release workflow passes the tag; a local build defaults to 0.0.0-dev, which is
# older than any release and so never claims to be up to date falsely.
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

# Quit a running copy first, otherwise the replaced bundle keeps executing the
# old binary and the state file can be left behind.
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

# Our own icon. The build previously borrowed CrossOver's .icns, which is
# CodeWeavers' artwork and could not ship in a released app.
if [ -f "$HERE/assets/Deadeye.icns" ]; then
	cp "$HERE/assets/Deadeye.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "warning: assets/Deadeye.icns missing — app will have no icon" >&2
fi

# Prefer a stable local identity over ad-hoc. Ad-hoc signing makes the app's
# designated requirement its own binary hash, so every rebuild looks like a
# different app to TCC and silently revokes Accessibility. A certificate-based
# identity makes the requirement "this bundle id, signed by this certificate",
# which survives rebuilds — the same reason shipping apps keep their permissions
# across updates.
# Accept either name. The certificate's common name is never shown to users, so
# renaming it would only cost a keychain password prompt and force every
# Accessibility grant to be redone — the grant is tied to the certificate.
SIGN_ID=""
for candidate in "Deadeye Local Signing" "mac-gaimgfix Local Signing"; do
	if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$candidate"; then
		SIGN_ID="$candidate"; break
	fi
done
if [ -n "$SIGN_ID" ]; then
	# --options runtime enables the hardened runtime. Deadeye works under it (the
	# event tap, the SkyLight dlopen and SetsCursorInBackground were all verified),
	# and notarisation requires it, so there is no reason to ship without it.
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
	# Clear the quarantine flag so Gatekeeper does not block a locally built,
	# ad-hoc signed bundle that was just copied.
	xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
	# Leaving the freshly built copy behind creates a SECOND bundle with the same
	# bundle identifier, which makes Accessibility grants ambiguous: the user can
	# authorise one copy while the other runs, and TCC treats them as rivals.
	rm -rf "$APP"
	echo "Installed: $DEST (build copy removed to keep one bundle identity)"
	# Detached, because a foreground `open` can block for minutes waiting on
	# LaunchServices after a bundle is replaced, which made the build look hung.
	( open "$DEST" >/dev/null 2>&1 & ) 
	echo "Launched from /Applications. Look for the Deadeye eye icon in your menu bar."
else
	echo "Open it, then look for the Deadeye eye icon in your menu bar."
fi
