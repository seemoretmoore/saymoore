#!/usr/bin/env bash
# Regenerate SayMoore.xcodeproj from project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

# The local self-signed identity is required for Debug builds on developer
# machines, but CI builds disable code signing entirely. Skip the check
# when running on GitHub Actions (CI=true is set automatically).
if [[ -z "${CI:-}" ]]; then
  if ! security find-identity -p codesigning -v | grep -q "SayMoore Self-Sign"; then
    echo "error: 'SayMoore Self-Sign' identity not found. Run: bash scripts/setup-signing.sh" >&2
    exit 1
  fi
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found." >&2
    echo "Install with: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate
echo "✓ SayMoore.xcodeproj regenerated."
