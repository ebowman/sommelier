#!/bin/bash
# Builds a Developer ID signed, hardened-runtime Release Sommelier.app (SwiftPM).
#
# Usage: scripts/build-app.sh
# Output: dist/Sommelier.app. Idempotent: a stale copy is removed first.
#
# Env: VERSION            overrides the VERSION file (e.g. make release VERSION=0.1.0)
#      CODESIGN_IDENTITY  pin an identity (else auto-detected Developer ID)
#      ALLOW_ADHOC=1      permit ad-hoc "-" signing when no identity exists
#                         (local testing only; cannot be notarized, no stable
#                         Accessibility grant across rebuilds)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

APP_NAME="Sommelier"
BUNDLE_ID="ie.boboco.sommelier"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ENTITLEMENTS="${REPO_ROOT}/Resources/Sommelier.entitlements"

if [ -z "${VERSION:-}" ]; then
    [ -f "${REPO_ROOT}/VERSION" ] || { echo "error: VERSION file not found and VERSION unset" >&2; exit 1; }
    VERSION="$(<"${REPO_ROOT}/VERSION")"
fi
VERSION="${VERSION#"${VERSION%%[![:space:]]*}"}"
VERSION="${VERSION%"${VERSION##*[![:space:]]}"}"
if ! [[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
    echo "error: invalid version '${VERSION}' (expected 1-4 dot-separated integers, e.g. 0.1.0)" >&2
    exit 1
fi
BUILD_NUMBER="$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo 1)"
# Exact provenance for scripts/publish-release.sh: the commit and whether tracked files were modified.
GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no 2>/dev/null)" ]; then GIT_DIRTY=1; else GIT_DIRTY=0; fi

# shellcheck source=lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/lib/resolve-codesign-identity.sh"
if [ -z "${CODESIGN_IDENTITY}" ]; then
    if [ "${ALLOW_ADHOC:-}" = "1" ]; then
        CODESIGN_IDENTITY="-"
        echo "==> WARNING: no Developer ID Application identity; ALLOW_ADHOC=1 set. AD-HOC build:" >&2
        echo "    cannot be notarized, no stable Accessibility grant. Local testing only." >&2
    else
        echo "error: no 'Developer ID Application' identity found (and CODESIGN_IDENTITY is unset)." >&2
        echo "       Install a certificate, set CODESIGN_IDENTITY, or ALLOW_ADHOC=1 for a local build." >&2
        exit 1
    fi
fi

echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
[ -x "${BIN}" ] || { echo "error: release binary not found at ${BIN}" >&2; exit 1; }

echo "==> Assembling ${APP_BUNDLE} (${VERSION}, build ${BUILD_NUMBER})"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" \
  -c "Add :CFBundleName string ${APP_NAME}" \
  -c "Add :CFBundleDisplayName string ${APP_NAME}" \
  -c "Add :CFBundleExecutable string ${APP_NAME}" \
  -c 'Add :CFBundlePackageType string APPL' \
  -c "Add :CFBundleVersion string ${BUILD_NUMBER}" \
  -c "Add :CFBundleShortVersionString string ${VERSION}" \
  -c "Add :SommelierGitCommit string ${GIT_COMMIT}" \
  -c "Add :SommelierGitDirty string ${GIT_DIRTY}" \
  -c 'Add :LSUIElement bool true' \
  -c 'Add :LSMinimumSystemVersion string 26.0' \
  -c 'Add :NSHumanReadableCopyright string Copyright 2026 Eric Bowman. MIT License.' \
  -c 'Add :NSAccessibilityUsageDescription string Sommelier uses Accessibility to read and arrange menu bar items.' \
  -c 'Add :NSScreenCaptureUsageDescription string Sommelier may capture the menu bar to show hidden items.' \
  "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Signing with: ${CODESIGN_IDENTITY}"
if [ "${CODESIGN_IDENTITY}" = "-" ]; then
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"
else
    codesign --force --sign "${CODESIGN_IDENTITY}" --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"
fi

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' || true
ENT="$(codesign -d --entitlements :- "${APP_BUNDLE}" 2>/dev/null || true)"
echo "==> Entitlements:"
echo "${ENT:-<none>}"
if printf '%s' "${ENT}" | grep -q 'com.apple.security.app-sandbox'; then
    echo "error: Sommelier must NOT be sandboxed (Accessibility API)." >&2; exit 1
fi
if printf '%s' "${ENT}" | grep -q 'com.apple.security.get-task-allow'; then
    echo "error: get-task-allow present; notarization would reject it." >&2; exit 1
fi
echo "==> Built version: $("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short) (build $("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" build))"
echo "==> Done: ${APP_BUNDLE}"
