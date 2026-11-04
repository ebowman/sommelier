#!/bin/bash
# Builds a signed, distributable DMG of Sommelier.app.
#
# Usage: scripts/make-dmg.sh
# Output: dist/Sommelier-<version>.dmg (<version> read back from the built
#         bundle via read-app-version.sh).
#
# ALWAYS runs scripts/build-app.sh first so the DMG can never contain a stale
# bundle. The DMG is signed with the same identity as the app (shared
# scripts/lib/resolve-codesign-identity.sh). No ad-hoc fallback: an ad-hoc DMG
# can never be notarized; set ALLOW_ADHOC_DMG=1 to opt in for local testing
# only (the app build then also needs ALLOW_ADHOC=1 when no identity exists).
#
# Idempotent; staging dir and any mount are cleaned via trap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"

APP_NAME="Sommelier"
VOLUME_NAME="Sommelier"
BUILD_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

STAGING_DIR=""
MOUNT_POINT=""

cleanup() {
    # Detach unconditionally (tolerating failure): mktemp returns /var/... while
    # mount(8) prints /private/var/..., so a `mount | grep` guard never matches.
    if [ -n "${MOUNT_POINT}" ]; then
        hdiutil detach "${MOUNT_POINT}" -quiet -force 2>/dev/null || true
    fi
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT

# shellcheck source=lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"

if [ -z "${CODESIGN_IDENTITY}" ]; then
    if [ "${ALLOW_ADHOC_DMG:-}" = "1" ]; then
        CODESIGN_IDENTITY="-"
        echo "==> WARNING: no Developer ID identity; ALLOW_ADHOC_DMG=1 set. Ad-hoc DMG can NEVER" >&2
        echo "    be notarized and must not be distributed — local testing only." >&2
    else
        echo "error: no Developer ID Application identity found (and CODESIGN_IDENTITY is unset)." >&2
        echo "       Refusing to produce an ad-hoc DMG. Install a Developer ID certificate, set" >&2
        echo "       CODESIGN_IDENTITY, or set ALLOW_ADHOC_DMG=1 for local testing only." >&2
        exit 1
    fi
fi
export CODESIGN_IDENTITY

echo "==> Building ${APP_NAME}.app..."
"${SCRIPT_DIR}/build-app.sh"

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "error: expected ${APP_BUNDLE} after build-app.sh, but it is missing" >&2
    exit 1
fi

SHORT_VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short)"
if [ -z "${SHORT_VERSION}" ]; then
    echo "error: could not read version from ${APP_BUNDLE}" >&2
    exit 1
fi

DMG_NAME="${APP_NAME}-${SHORT_VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

echo "==> Staging DMG contents..."
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sommelier-dmg-staging.XXXXXX")"
ditto "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"

echo "==> Creating ${DMG_NAME}..."
# `hdiutil create` is deprecated on macOS 27. diskutil creates an APFS volume
# (hdiutil defaulted to HFS+), which is fine for the macOS 26 deployment
# target. No -ov equivalent: DMG_PATH was removed above. The image is not
# mounted afterwards; `set -e` aborts on a non-zero exit.
diskutil image create from --format UDZO --volumeName "${VOLUME_NAME}" "${STAGING_DIR}" "${DMG_PATH}"

# Fixed identifier: codesign would otherwise derive a filename-based one,
# truncated at the first dot ("Sommelier-0"), which changes per release.
DMG_IDENTIFIER="ie.boboco.Sommelier.dmg"
echo "==> Code-signing ${DMG_NAME} with: ${CODESIGN_IDENTITY}"
if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    codesign --force --sign - --identifier "${DMG_IDENTIFIER}" "${DMG_PATH}"
else
    codesign --force --sign "${CODESIGN_IDENTITY}" --identifier "${DMG_IDENTIFIER}" --timestamp "${DMG_PATH}"
fi

echo "==> Verifying DMG signature..."
codesign --verify --verbose=2 "${DMG_PATH}"

echo "==> Verifying mounted DMG contents..."
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/sommelier-dmg-mount.XXXXXX")"
rmdir "${MOUNT_POINT}"
hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet -readonly
[ -d "${MOUNT_POINT}/${APP_NAME}.app" ] || { echo "error: ${APP_NAME}.app not found inside mounted DMG" >&2; exit 1; }
[ -L "${MOUNT_POINT}/Applications" ] || { echo "error: Applications symlink not found inside mounted DMG" >&2; exit 1; }
hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

echo "==> Done: ${DMG_PATH}"
