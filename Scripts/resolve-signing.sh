#!/usr/bin/env bash
# Shared signing resolution for release scripts.
# Set RELEASE_IDENTITY and optionally RELEASE_TEAM, or we pick the first
# "Developer ID Application" identity in the login keychain.
set -euo pipefail

resolve_release_signing() {
  if [ -n "${RELEASE_IDENTITY:-}" ]; then
    identity="$RELEASE_IDENTITY"
  else
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | grep 'Developer ID Application' | head -1 \
      | sed -n 's/.*"\(.*\)"/\1/')"
  fi

  if [ -z "${identity:-}" ]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    echo "" >&2
    echo "For a distributable dmg: join the Apple Developer Program, create a" >&2
    echo "Developer ID Application cert in Xcode, then run make release again." >&2
    echo "" >&2
    echo "Or build a local-only dmg (ad-hoc signed, not notarized):" >&2
    echo "  make dmg-adhoc" >&2
    echo "" >&2
    echo "You can also set RELEASE_IDENTITY and RELEASE_TEAM explicitly." >&2
    security find-identity -v -p codesigning 2>/dev/null || true
    return 1
  fi

  if [ -n "${RELEASE_TEAM:-}" ]; then
    team="$RELEASE_TEAM"
  else
    team="$(printf '%s' "$identity" | sed -n 's/.*(\([^)]*\))$/\1/p')"
  fi

  if [ -z "$team" ]; then
    echo "Could not read team id from identity. Set RELEASE_TEAM." >&2
    return 1
  fi

  security find-identity -v -p codesigning 2>/dev/null | grep -q "$identity" || {
    echo "Certificate not found: $identity" >&2
    return 1
  }
}
