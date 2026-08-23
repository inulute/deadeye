#!/bin/bash
#
# Deadeye. Copyright (C) 2026 inulute.
# Licensed under the GNU General Public License v3.0. See LICENSE.
#
# Creates a local, self-signed code-signing identity so that rebuilding the app
# stops revoking its Accessibility permission.
#
# The problem it solves: an ad-hoc signed app's designated requirement is its own
# binary hash —
#
#     designated => cdhash H"30d00730..."
#
# so every rebuild is a different app as far as TCC is concerned, and the grant is
# void. A properly signed app is identified by bundle id plus signing certificate:
#
#     designated => identifier "com.deadeye.Deadeye" and certificate leaf = H"..."
#
# which stays constant across rebuilds. That is exactly how shipping apps keep
# their permissions through updates; Developer ID just uses Apple's chain instead
# of a local certificate.
#
#   ./create-signing-identity.sh            create it (idempotent)
#   ./create-signing-identity.sh --remove   delete it
#
set -euo pipefail

CN="Deadeye Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Usable means listed AND without an error marker such as CSSMERR_TP_NOT_TRUSTED.
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
	# Present is not the same as usable. An interrupted run can leave the
	# certificate imported but untrusted, which shows up as CSSMERR_TP_NOT_TRUSTED
	# and makes codesign refuse it. Repair that case rather than exiting.
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

# Code signing needs the codeSigning EKU; without it codesign refuses the identity.
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

# macOS `security` cannot read OpenSSL 3's default PKCS#12 encryption — it fails
# with "MAC verification failed during PKCS12 import". The legacy PBE algorithms
# below are what it understands. Verified by trying both.
openssl pkcs12 -export -out "$WORK/identity.p12" \
	-inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	-name "$CN" -passout pass:gaimgfix \
	-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null

echo "Importing into the login keychain…"
# -T /usr/bin/codesign lets codesign use the key without prompting every time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P gaimgfix \
	-T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Without trust settings the certificate chains to an untrusted root and codesign
# rejects it. Trust is scoped to code signing only, in the user's own keychain.
echo "Marking it trusted for code signing (may ask for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null \
	|| echo "  note: could not set trust automatically — see the message below"

# Stop the keychain prompting on every codesign invocation.
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
