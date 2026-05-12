#!/usr/bin/env bash
# Idempotently create a self-signed code-signing identity for SayMoore in the
# login keychain. The identity name is stable across runs so that macOS TCC
# (Accessibility, Input Monitoring) does not revoke previously-granted
# permissions when the app is rebuilt.
#
# Usage:
#   bash scripts/setup-signing.sh             # create if missing, no-op if present
#   bash scripts/setup-signing.sh --force-regen   # destroy + recreate (re-prompts permissions)

set -euo pipefail

CERT_NAME="SayMoore Self-Sign"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DAYS=3650
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force-regen) FORCE=1 ;;
        -h|--help)
            sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

cert_exists() {
    security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1
}

identity_exists() {
    # Self-signed certs are not "valid" per system trust policy, but codesign
    # accepts them when the identity is named explicitly. We accept any matching
    # identity in the codesigning policy bucket, trusted or not.
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | grep -F "\"$CERT_NAME\"" >/dev/null 2>&1
}

if cert_exists && identity_exists; then
    if [[ $FORCE -eq 0 ]]; then
        echo "✓ Cert \"$CERT_NAME\" already in login keychain — leaving alone."
        echo "  (Pass --force-regen to rotate. This will revoke Accessibility/Input-Monitoring grants.)"
        exit 0
    fi

    cat <<'BANNER' >&2
╔══════════════════════════════════════════════════════════════════════╗
║  --force-regen will DELETE the existing "SayMoore Self-Sign" cert.   ║
║  All previously-granted Accessibility, Input Monitoring, and other   ║
║  TCC permissions WILL BE REVOKED on the next launch.                 ║
║  You will have to re-grant them in System Settings.                  ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER
    read -r -p "Type YES to continue: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted." >&2
        exit 1
    fi

    echo "Removing existing identity…"
    while cert_exists; do
        security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1 || break
    done
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CFG="$TMPDIR/openssl.cnf"
KEY="$TMPDIR/saymoore.key"
CRT="$TMPDIR/saymoore.crt"
P12="$TMPDIR/saymoore.p12"
P12_PASS="$(uuidgen)"

cat > "$CFG" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3
[ dn ]
CN = ${CERT_NAME}
[ v3 ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CRT" \
    -days "$DAYS" -config "$CFG" >/dev/null 2>&1

openssl pkcs12 -export -legacy -inkey "$KEY" -in "$CRT" \
    -name "$CERT_NAME" -out "$P12" -passout "pass:$P12_PASS" >/dev/null 2>&1

echo "Importing into login keychain…"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productsign >/dev/null

# Grant codesign non-interactive access to the imported private key.
# Without this, every codesign invocation pops a GUI keychain prompt and
# xcodebuild will hang. Requires the login-keychain password.
echo
echo "To allow codesign to use the new key without a GUI prompt every build,"
echo "we need to grant partition access. macOS will ask for your *login*"
echo "password (the one you log into this Mac with)."
if ! security set-key-partition-list \
        -S apple-tool:,apple:,codesign:,productsign: \
        -s "$KEYCHAIN" >/dev/null; then
    cat >&2 <<'WARN'

⚠ set-key-partition-list failed. The cert is installed but codesign will
  show a GUI prompt the first time it uses the key. Click "Always Allow"
  to suppress future prompts.
WARN
fi

if identity_exists; then
    echo "✓ Identity \"$CERT_NAME\" installed."
    echo "  Verify with: security find-identity -p codesigning -v"
else
    echo "⚠ Cert imported but identity not visible to codesigning policy." >&2
    echo "  Open Keychain Access, locate \"$CERT_NAME\", and ensure trust is set to" >&2
    echo "  \"Always Trust\" for Code Signing." >&2
    exit 3
fi
