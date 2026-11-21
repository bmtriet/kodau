#!/usr/bin/env bash
# Creates a stable, local-only code signing identity ("Kodau Local Code Signing") in the login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS TCC treats each rebuild of Kodau.app as a new
# app and silently drops its Accessibility permission. Signing every build with the SAME certificate
# keeps the designated requirement stable, so the permission survives rebuilds.
#
# Safe to re-run: does nothing if the identity already exists. The certificate is self-signed, never
# leaves this Mac, and is only usable by /usr/bin/codesign without a password prompt.
set -euo pipefail

IDENTITY="${KODAU_SIGN_IDENTITY:-Kodau Local Code Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -q "\"${IDENTITY}\""; then
    echo "✅ Signing identity '${IDENTITY}' already exists."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

cat > "${WORK_DIR}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${IDENTITY}
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> Generating self-signed code signing certificate '${IDENTITY}' (10 years)..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "${WORK_DIR}/openssl.cnf" \
    -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" >/dev/null 2>&1

P12_PASS="kodau-$(date +%s)"
openssl pkcs12 -export -name "${IDENTITY}" \
    -inkey "${WORK_DIR}/key.pem" -in "${WORK_DIR}/cert.pem" \
    -out "${WORK_DIR}/identity.p12" -passout "pass:${P12_PASS}"

echo "==> Importing into login keychain (usable by codesign without prompts)..."
security import "${WORK_DIR}/identity.p12" -k "${KEYCHAIN}" -P "${P12_PASS}" -T /usr/bin/codesign >/dev/null

echo "✅ Created '${IDENTITY}'. build_app.sh / install_im.sh will now sign with it automatically."
echo "   After the next build, re-enable Kodau once in System Settings → Privacy & Security → Accessibility;"
echo "   from then on the permission survives rebuilds."
