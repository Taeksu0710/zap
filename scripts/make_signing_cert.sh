#!/bin/bash
# Creates a reusable self-signed code-signing certificate in the login
# keychain, so Zap.app can be signed with a STABLE identity across rebuilds.
#
# Why this matters: ad-hoc signing (`codesign --sign -`) derives the app's
# TCC identity from a hash of the compiled binary (cdhash), which changes on
# every rebuild. Since TCC keys Full Disk Access grants on that identity for
# ad-hoc code, every `install_app.sh` run silently invalidates any FDA grant
# the user already gave. Signing with a certificate instead anchors identity
# to the certificate itself (stable across rebuilds), so FDA grants survive.
#
# Run this once per machine. build_app.sh auto-detects the certificate and
# uses it; if it's missing, build_app.sh falls back to ad-hoc with a warning.
set -euo pipefail

CERT_NAME="Zap Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "Certificate \"$CERT_NAME\" already exists in the login keychain — nothing to do."
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> generating self-signed code-signing certificate \"$CERT_NAME\""

cat > "$WORK_DIR/openssl.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no

[req_distinguished_name]
CN = $CERT_NAME

[codesign_ext]
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:TRUE
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK_DIR/key.pem" \
  -out "$WORK_DIR/cert.pem" \
  -days 3650 \
  -config "$WORK_DIR/openssl.cnf"

# An empty-string PKCS12 password causes macOS's importer to fail MAC
# verification (a long-standing OpenSSL/Apple interop quirk — empty-string
# vs. no-password hash differently). Use a throwaway non-empty passphrase for
# this transient export file instead; it's deleted immediately after import.
P12_PASS="$(openssl rand -base64 24)"
openssl pkcs12 -export -legacy \
  -inkey "$WORK_DIR/key.pem" \
  -in "$WORK_DIR/cert.pem" \
  -out "$WORK_DIR/cert.p12" \
  -passout "pass:$P12_PASS" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1

echo "==> importing into login keychain"
echo "    (macOS may ask to allow codesign access to this key — choose \"Always Allow\")"
security import "$WORK_DIR/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security

echo "==> marking certificate trusted for code signing (your user, not system-wide)"
# trustRoot (not trustAsRoot): this cert is self-signed and IS its own root,
# so it validates itself as a trust anchor rather than chaining to one.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem" || {
  echo "warning: could not set trust automatically." >&2
  echo "You can trust it manually in Keychain Access: find \"$CERT_NAME\", expand Trust, set Code Signing to Always Trust." >&2
}

echo "==> done. scripts/build_app.sh will now sign with \"$CERT_NAME\" instead of ad-hoc."
