# Resolves CODESIGN_IDENTITY: the code-signing identity used for both
# Sommelier.app (scripts/build-app.sh) and its DMG (scripts/make-dmg.sh).
#
# Meant to be SOURCED, not executed, from a `set -euo pipefail` script:
#
#   # shellcheck source=lib/resolve-codesign-identity.sh
#   source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"
#
# Behaviour (identical for build-app.sh and make-dmg.sh so a rebuilt app and
# its DMG are always signed with the same identity):
#   1. If CODESIGN_IDENTITY is already set in the environment, use it as-is.
#   2. Otherwise auto-detect a "Developer ID Application: ..." identity via
#      `security find-identity -v -p codesigning`, preferring one that
#      contains the team id Y5SB82BPYL, else the first one found.
#   3. If neither is available, CODESIGN_IDENTITY is left empty; callers
#      decide whether an empty identity (ad-hoc fallback) is acceptable.
#
# Why Developer ID: the designated requirement of a Developer ID signature is
# keyed on bundle identifier + team, so it is STABLE across rebuilds. An
# ad-hoc identity (`--sign -`) is derived from the binary's own hash and
# changes on every rebuild, which makes macOS treat each build as a new app
# and invalidates the Accessibility (TCC) grant Sommelier needs, forcing the
# user to re-grant it after every rebuild.
#
# On exit: CODESIGN_IDENTITY is set (possibly to "").

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    _sommelier_ids="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' || true)"
    CODESIGN_IDENTITY="$(printf '%s\n' "${_sommelier_ids}" | grep 'Y5SB82BPYL' | head -1 || true)"
    if [ -z "${CODESIGN_IDENTITY}" ]; then
        CODESIGN_IDENTITY="$(printf '%s\n' "${_sommelier_ids}" | sed -n '1p')"
    fi
    unset _sommelier_ids
fi
