#!/bin/bash
# OPERATOR-INVOKED ONLY: publishes the notarized DMG as a GitHub release.
# Usage: CONFIRM_PUBLISH=1 scripts/publish-release.sh [--dry-run]
# Tag is v<version> (the VERSION file). Uploads the DMG and a .sha256 file.
# --dry-run runs EVERY check (same refusals) and prints the gh command only.
#
# Refuses unless: the working tree has no tracked changes (untracked files are
# ignored); the app INSIDE the DMG has CFBundleVersion == `git rev-list --count HEAD`
# (the formula build-app.sh uses, i.e. the DMG was built from HEAD) and
# CFBundleShortVersionString == VERSION; the DMG passes spctl and has a stapled
# ticket; the tag does not exist locally or on origin. If HEAD moved since the
# build, rebuild AND re-notarize: make release && make notarize.
# Also: the embedded SommelierGitCommit must equal `git rev-parse HEAD` and SommelierGitDirty
# must be 0 (exact check; DMGs without the key are refused); the stapled app inside the DMG
# must pass `xcrun stapler validate`.
set -euo pipefail
NOTES_FILE=""
MOUNT_POINT=""
cleanup() {
    if [ -n "${MOUNT_POINT}" ]; then
        hdiutil detach "${MOUNT_POINT}" -quiet -force >/dev/null 2>&1 || true
        rmdir "${MOUNT_POINT}" 2>/dev/null || true
    fi
    if [ "${DRY_RUN:-0}" = "1" ] && [ -n "${NOTES_FILE}" ]; then rm -f "${NOTES_FILE}"; fi
}
trap cleanup EXIT
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

ORIGIN_URL="$(git config --get remote.origin.url 2>/dev/null)" || fail "no git remote named 'origin'"
if [[ "${ORIGIN_URL}" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]] \
    || [[ "${ORIGIN_URL}" =~ ^ssh://git@github\.com/([^/]+)/([^/]+)$ ]] \
    || [[ "${ORIGIN_URL}" =~ ^https://([^@/]+@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    OWNER="${BASH_REMATCH[$((${#BASH_REMATCH[@]} - 2))]}"
    REPO="${BASH_REMATCH[$((${#BASH_REMATCH[@]} - 1))]}"
    REPO="${REPO%.git}"
else
    fail "cannot parse OWNER/REPO from origin URL '${ORIGIN_URL}'"
fi

[ -f VERSION ] || fail "VERSION file not found"
VERSION="$(<VERSION)"
VERSION="${VERSION#"${VERSION%%[![:space:]]*}"}"
VERSION="${VERSION%"${VERSION##*[![:space:]]}"}"
[ -n "${VERSION}" ] || fail "VERSION file is empty"

[ -z "$(git status --porcelain --untracked-files=no)" ] \
    || fail "working tree has tracked changes; a release must describe an exact commit"

TAG="v${VERSION}"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && fail "tag ${TAG} already exists locally"
REMOTE_TAGS="$(git ls-remote --tags origin "refs/tags/${TAG}")" || fail "cannot query tags on origin"
[ -z "${REMOTE_TAGS}" ] || fail "tag ${TAG} already exists on origin"

DMG="dist/Sommelier-${VERSION}.dmg"
[ -f "${DMG}" ] || fail "DMG not found at ${DMG} (run make release && make notarize)"

# Read the app version fields from INSIDE the DMG (that is what users get).
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/sommelier-publish-mount.XXXXXX")"
hdiutil attach "${DMG}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet -readonly \
    || fail "cannot mount ${DMG}"
INFO_PLIST="${MOUNT_POINT}/Sommelier.app/Contents/Info.plist"
[ -f "${INFO_PLIST}" ] || fail "no Sommelier.app/Contents/Info.plist inside ${DMG}"
EMBEDDED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}" 2>/dev/null)" \
    || fail "CFBundleVersion missing from the app inside ${DMG}"
EMBEDDED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}" 2>/dev/null)" \
    || fail "CFBundleShortVersionString missing from the app inside ${DMG}"
EMBEDDED_SHA="$(/usr/libexec/PlistBuddy -c 'Print :SommelierGitCommit' "${INFO_PLIST}" 2>/dev/null)" || EMBEDDED_SHA=""
EMBEDDED_DIRTY="$(/usr/libexec/PlistBuddy -c 'Print :SommelierGitDirty' "${INFO_PLIST}" 2>/dev/null)" || EMBEDDED_DIRTY=""
# Validate the stapled ticket on the app itself (users copy the app out of the DMG).
INNER_STAPLE_OK=1
xcrun stapler validate "${MOUNT_POINT}/Sommelier.app" >/dev/null 2>&1 || INNER_STAPLE_OK=0
hdiutil detach "${MOUNT_POINT}" -quiet >/dev/null 2>&1 || true

HEAD_COUNT="$(git rev-list --count HEAD)"
[ "${EMBEDDED_BUILD}" = "${HEAD_COUNT}" ] \
    || fail "DMG was not built from HEAD: embedded CFBundleVersion ${EMBEDDED_BUILD} != commit count ${HEAD_COUNT} (rebuild and re-notarize: make release && make notarize)"
[ -n "${EMBEDDED_SHA}" ] \
    || fail "DMG predates the SHA check (no SommelierGitCommit in the app); rebuild and re-notarize: make release && make notarize"
HEAD_SHA="$(git rev-parse HEAD)"
[ "${EMBEDDED_SHA}" = "${HEAD_SHA}" ] \
    || fail "DMG was not built from HEAD: embedded git commit ${EMBEDDED_SHA} != ${HEAD_SHA} (rebuild and re-notarize: make release && make notarize)"
[ "${EMBEDDED_DIRTY}" = "0" ] \
    || fail "DMG was built from a dirty tree (SommelierGitDirty='${EMBEDDED_DIRTY}'); commit first, then rebuild and re-notarize"
[ "${INNER_STAPLE_OK}" = "1" ] \
    || fail "the app inside ${DMG} has no valid stapled notarization ticket (xcrun stapler validate failed)"
[ "${EMBEDDED_VERSION}" = "${VERSION}" ] \
    || fail "embedded CFBundleShortVersionString ${EMBEDDED_VERSION} != VERSION ${VERSION}"

spctl -a -t open --context context:primary-signature "${DMG}" 2>/dev/null \
    || fail "${DMG} does not pass spctl Gatekeeper assessment (notarize it)"
xcrun stapler validate "${DMG}" >/dev/null 2>&1 || fail "${DMG} has no valid stapled notarization ticket"

SHA256="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
[ -n "${SHA256}" ] || fail "could not compute sha256"
SHA_FILE="dist/Sommelier-${VERSION}.dmg.sha256"
echo "tag:    ${TAG} (HEAD $(git rev-parse --short HEAD), build ${HEAD_COUNT})"
echo "dmg:    ${DMG}"
echo "sha256: ${SHA256}"
if [ "${DRY_RUN}" != "1" ]; then
    echo "${SHA256}  Sommelier-${VERSION}.dmg" > "${SHA_FILE}"
fi

NOTES_FILE="dist/release-notes.md"
if [ "${DRY_RUN}" = "1" ]; then NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/sommelier-notes.XXXXXX")"; fi
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
    echo "DRY RUN: all checks passed; nothing will be created or uploaded."
    printf '%q ' "${GH_CMD[@]}"; echo
    exit 0
fi
"${GH_CMD[@]}"
echo "Release: https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}"
