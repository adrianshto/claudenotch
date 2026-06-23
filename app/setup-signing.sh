#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity in a dedicated
# keychain. build-app.sh signs with it so the app has a consistent identity —
# which is what lets the Accessibility permission STICK across rebuilds (ad-hoc
# signing has no stable identity, so the grant keeps dropping).
# Uses its own keychain (password below); your LOGIN keychain is never touched.
# Idempotent — re-running recreates the identity.
set -euo pipefail

KC="$HOME/Library/Keychains/claudenotch.keychain-db"
KCPASS="claudenotch"
CERT="ClaudeNotch Self-Signed"
WORK=$(mktemp -d)

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$CERT
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
# -legacy MAC/PBE so Apple's `security import` can read the OpenSSL 3.x .p12
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
  -passout pass:cnp12 -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -legacy 2>/dev/null

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "cnp12" -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
EXISTING=$(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.+)"[[:space:]]*$/\1/')
security list-keychains -d user -s "$KC" $EXISTING
rm -rf "$WORK"

echo "Created code-signing identity '$CERT' in $KC"
