#!/usr/bin/env bash
# One time: creates a self-signed code-signing certificate and stores it as GitHub Actions
# secrets, so every build of LiveSubs carries the same signature. macOS then keeps the
# "Screen & System Audio Recording" permission across updates.
# Needs: openssl, gh (logged in), run from the repo. Files go to signing/ (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p signing && chmod 700 signing
if [ ! -f signing/livesubs.p12 ]; then
  PASS="$(openssl rand -hex 16)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout signing/livesubs.key -out signing/livesubs.cer \
    -subj "/CN=LiveSubs Self-Signed" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"
  # -legacy: macOS `security import` can't read OpenSSL 3's default p12 encryption.
  openssl pkcs12 -export -legacy -inkey signing/livesubs.key -in signing/livesubs.cer \
    -name "LiveSubs Self-Signed" -out signing/livesubs.p12 -passout "pass:$PASS"
  printf '%s' "$PASS" > signing/p12-password && chmod 600 signing/*
  echo "Created signing/livesubs.p12 (keep a backup: losing it means re-granting permission once)."
fi
base64 -w0 signing/livesubs.p12 | gh secret set SIGN_P12_BASE64
gh secret set SIGN_P12_PASSWORD < signing/p12-password
echo "GitHub secrets SIGN_P12_BASE64 and SIGN_P12_PASSWORD set."
