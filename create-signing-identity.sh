#!/bin/bash
#
# Deadeye. Copyright (C) 2026 inulute.
# Licensed under the GNU General Public License v3.0. See LICENSE.
#
set -euo pipefail

CN="Deadeye Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

is_usable() {
	security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
		| grep -F "$CN" | grep -qv CSSMERR
}

if [ "${1:-}" = "--remove" ]; then
	security delete-identity -c "$CN" "$KEYCHAIN" 2>/dev/null || true
	security delete-certificate -c "$CN" "$KEYCHAIN" 2>/dev/null || true
	echo "Removed '$CN'."
	exit 0
fi

if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
	if is_usable; then
		echo "Identity '$CN' already exists and is usable."
		security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CN"
		exit 0
	fi

	echo "Identity '$CN' exists but is not trusted for code signing. Repairing…"
	security find-certificate -c "$CN" -p "$KEYCHAIN" >"$WORK/existing.pem"
	security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/existing.pem"
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

	if is_usable; then
		echo "Repaired — now usable:"
		security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CN"
		exit 0
	fi
	echo "Still not trusted. Open Keychain Access, find '$CN' under login >" >&2
	echo "My Certificates, Get Info > Trust > Code Signing > Always Trust." >&2
	exit 1
fi

cat >"$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = Deadeye Local Signing

[v3]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

echo "Generating key and self-signed certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
	-config "$WORK/openssl.cnf" \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
	-inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	-name "$CN" -passout pass:gaimgfix \
	-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null

echo "Importing into the login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P gaimgfix \
	-T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Marking it trusted for code signing (may ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null \
	|| echo "  note: could not set trust automatically — see the message below"

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if is_usable; then
	echo "SUCCESS — usable code-signing identity:"
	security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$CN"
	echo
	echo "build.sh will pick this up automatically."
	echo "You must grant Accessibility ONE more time after the next build; from then"
	echo "on the grant survives rebuilds."
else
	echo "Certificate imported but not yet valid for code signing."
	echo "Open Keychain Access, find '$CN' under login > My Certificates,"
	echo "Get Info > Trust > 'Code Signing' > Always Trust, then re-run this script."
fi
