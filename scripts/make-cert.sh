#!/bin/bash
# One-time: make a free self-signed code-signing certificate called "Read Aloud Dev"
# and put it in the login keychain. Every build is signed with it, so macOS sees
# the same app each time and keeps its permissions (Accessibility) across rebuilds.
set -euo pipefail
NAME="Read Aloud Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already have '$NAME'."; exit 0; fi
D="$HOME/.local/share/read-aloud/signing"; mkdir -p "$D"; chmod 700 "$D"
cat > "$D/cert.cnf" <<CNF
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
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$D/key.pem" -out "$D/cert.pem" -config "$D/cert.cnf" 2>/dev/null
P="readaloud-local"
openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" -out "$D/cert.p12" -passout pass:$P 2>/dev/null
chmod 600 "$D"/*
security import "$D/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P" -T /usr/bin/codesign
security find-identity -p codesigning | grep "$NAME"
