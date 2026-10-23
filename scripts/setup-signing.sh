#!/usr/bin/env bash
# One-time: creates a self-signed code signing certificate in your login keychain.
# Signing every build with the same identity means macOS remembers the Screen Recording
# permission across rebuilds. Remove it any time in Keychain Access ("SSIN Local Signing").
set -euo pipefail

NAME="SSIN Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout pass:ssin 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
       -out "$TMP/identity.p12" -passout pass:ssin
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P ssin -T /usr/bin/codesign >/dev/null
echo "✓ Created '$NAME'. Rebuild with scripts/build-app.sh"
