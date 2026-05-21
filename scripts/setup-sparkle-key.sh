#!/usr/bin/env bash
# Generate an EdDSA key pair for Sparkle appcast signing. Sparkle's generate_keys
# stores the private key in the login Keychain itself; we just pin the account
# name so build-release.sh can look it up deterministically.
#
# Idempotent: if a key already exists under the SayMoore account, prints the
# public key and exits 0. Use --force-regen to rotate (will break updates for
# every shipped build whose Info.plist pins the old public key).

set -euo pipefail

cd "$(dirname "$0")/.."

ACCOUNT="SayMoore"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force-regen) FORCE=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

GENERATE_KEYS="build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$GENERATE_KEYS" ]]; then
    echo "error: $GENERATE_KEYS not found. Build SayMoore once first so the Sparkle SPM artifact is resolved." >&2
    exit 1
fi

# Sparkle stores the private key under service "https://sparkle-project.org"
# keyed by --account. Existence check probes that entry directly.
if security find-generic-password -a "$ACCOUNT" -s "https://sparkle-project.org" >/dev/null 2>&1; then
    if [[ $FORCE -eq 1 ]]; then
        security delete-generic-password -a "$ACCOUNT" -s "https://sparkle-project.org" >/dev/null
        echo "warning: rotating Sparkle key — all builds signed with the old key will stop receiving updates." >&2
    else
        # Already exists; just print the public key.
        PUBLIC_KEY=$("$GENERATE_KEYS" --account "$ACCOUNT" -p | tr -d '[:space:]')
        echo "Existing Sparkle key found. Public key:"
        echo "  $PUBLIC_KEY"
        exit 0
    fi
fi

# First run (or post-rotation): generate fresh. Without -p, generate_keys
# creates the key in-Keychain and prints the public key + Info.plist snippet
# to stdout. Re-query with -p to get just the bare public key.
"$GENERATE_KEYS" --account "$ACCOUNT" >/dev/null
PUBLIC_KEY=$("$GENERATE_KEYS" --account "$ACCOUNT" -p | tr -d '[:space:]')

echo
echo "==============================================================="
echo "Sparkle EdDSA key generated."
echo
echo "Public key (paste into Info.plist <key>SUPublicEDKey</key>):"
echo
echo "  $PUBLIC_KEY"
echo
echo "Private key stored in login Keychain under account '$ACCOUNT'."
echo "build-release.sh reads it via: sign_update --account $ACCOUNT"
echo "==============================================================="
