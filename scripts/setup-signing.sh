#!/usr/bin/env bash
# Creates a local self-signed code-signing identity so the app keeps ONE stable
# code signature across rebuilds.
#
# Why this exists: an ad-hoc signature's designated requirement is a bare cdhash,
# which changes on every build. macOS keys Accessibility, Input Monitoring, and
# Screen Recording grants to that requirement, so every rebuild would silently
# revoke all three. A stable identity makes the grants persist.
#
# Everything lives in ~/.intelligent-cursor/signing and nothing else on the system
# is modified. To undo completely:
#   security delete-keychain ~/Library/Keychains/intelligent-cursor-dev.keychain-db
#   rm -rf ~/.intelligent-cursor/signing
set -euo pipefail

IDENTITY_NAME="Intelligent Cursor Dev"
SIGNING_DIR="$HOME/.intelligent-cursor/signing"
KEYCHAIN="$HOME/Library/Keychains/intelligent-cursor-dev.keychain-db"
KEYCHAIN_SHORT="intelligent-cursor-dev.keychain"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"

if [[ -f "$PASSWORD_FILE" ]] && security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "already configured: $IDENTITY_NAME"
    exit 0
fi

mkdir -p "$SIGNING_DIR"
chmod 700 "$HOME/.intelligent-cursor" "$SIGNING_DIR"

if [[ ! -f "$PASSWORD_FILE" ]]; then
    umask 077
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
fi
PASSWORD="$(cat "$PASSWORD_FILE")"

umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$SIGNING_DIR/key.pem" \
    -out "$SIGNING_DIR/cert.pem" \
    -subj "/CN=$IDENTITY_NAME/O=Personal" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export \
    -inkey "$SIGNING_DIR/key.pem" \
    -in "$SIGNING_DIR/cert.pem" \
    -out "$SIGNING_DIR/identity.p12" \
    -name "$IDENTITY_NAME" \
    -passout "pass:$PASSWORD"

if [[ -f "$KEYCHAIN" ]]; then
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
fi
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$SIGNING_DIR/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# Keep the dev keychain in the user search list so codesign can find the identity.
EXISTING=()
while IFS= read -r line; do
    entry="$(echo "$line" | tr -d '"' | xargs)"
    [[ -n "$entry" && "$entry" != "$KEYCHAIN" ]] && EXISTING+=("$entry")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${EXISTING[@]}" "$KEYCHAIN"

security find-identity -v -p codesigning "$KEYCHAIN"
