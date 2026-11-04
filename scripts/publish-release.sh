#!/bin/bash
# OPERATOR-INVOKED ONLY: publishes the notarized DMG as a GitHub release.
# Usage: CONFIRM_PUBLISH=1 scripts/publish-release.sh [--dry-run]
# Tag is v<version> (version read from the built bundle). Uploads the DMG and a
# .sha256 file. --dry-run runs all preconditions and prints the gh command only.
set -euo pipefail
fail() { echo "error: $*" >&2; exit 1; }

DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "Usage: $(basename "$0") [--dry-run]" >&2; exit 1 ;;
esac
if [ "${DRY_RUN}" != "1" ] && [ "${CONFIRM_PUBLISH:-}" != "1" ]; then
    fail "refusing to publish: set CONFIRM_PUBLISH=1 (this creates a real, public GitHub release)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" || fail "no git remote named 'origin'"
if [[ "${ORIGIN_URL}" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]] \
    || [[ "${ORIGIN_URL}" =~ ^ssh://git@github\.com/([^/]+)/([^/]+)$ ]] \
    || [[ "${ORIGIN_URL}" =~ ^https://([^@/]+@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    OWNER="${BASH_REMATCH[$((${#BASH_REMATCH[@]} - 2))]}"
    REPO="${BASH_REMATCH[$((${#BASH_REMATCH[@]} - 1))]}"
    REPO="${REPO%.git}"
else
    fail "cannot parse OWNER/REPO from origin URL '${ORIGIN_URL}'"
fi

VERSION="$("${SCRIPT_DIR}/read-app-version.sh" short)" || fail "cannot read version from dist/Sommelier.app (run make release)"
[ -n "${VERSION}" ] || fail "built bundle reported an empty version"

if [ -n "$(git status --porcelain)" ]; then
    if [ "${DRY_RUN}" = "1" ]; then echo "warning: working tree not clean (dry run)" >&2
    else fail "working tree is not clean; a release must describe an exact commit"; fi
fi

TAG="v${VERSION}"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && fail "tag ${TAG} already exists locally"
REMOTE_TAGS="$(git ls-remote --tags origin "refs/tags/${TAG}")" || fail "cannot query tags on origin"
[ -z "${REMOTE_TAGS}" ] || fail "tag ${TAG} already exists on origin"

DMG="dist/Sommelier-${VERSION}.dmg"
[ -f "${DMG}" ] || fail "DMG not found at ${DMG} (run make release && make notarize)"
spctl -a -t open --context context:primary-signature "${DMG}" 2>/dev/null \
    || fail "${DMG} does not pass spctl Gatekeeper assessment (notarize it)"
xcrun stapler validate "${DMG}" >/dev/null 2>&1 || fail "${DMG} has no valid stapled notarization ticket"

SHA256="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
[ -n "${SHA256}" ] || fail "could not compute sha256"
SHA_FILE="dist/Sommelier-${VERSION}.dmg.sha256"
echo "${SHA256}  Sommelier-${VERSION}.dmg" > "${SHA_FILE}"

NOTES_FILE="dist/release-notes.md"
cat > "${NOTES_FILE}" <<NOTES
# Sommelier ${VERSION}

Alpha. macOS 26+ only (tested on 27.0.1).

SHA-256 of Sommelier-${VERSION}.dmg: \`${SHA256}\`

## Install

1. Open the DMG and drag Sommelier to Applications.
2. Launch it and grant Accessibility access (System Settings > Privacy & Security).

See the README for usage and known limitations.
NOTES

GH_CMD=(gh release create "${TAG}" "${DMG}" "${SHA_FILE}" --title "Sommelier ${VERSION}" --notes-file "${NOTES_FILE}" --repo "${OWNER}/${REPO}")
if [ "${DRY_RUN}" = "1" ]; then
    echo "DRY RUN: nothing will be created."
    printf '%q ' "${GH_CMD[@]}"; echo
    exit 0
fi
"${GH_CMD[@]}"
echo "Release: https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}"
