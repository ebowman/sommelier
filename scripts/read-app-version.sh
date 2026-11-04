#!/bin/bash
# Reads CFBundleShortVersionString / CFBundleVersion back OUT of a BUILT .app.
# Usage: scripts/read-app-version.sh [path-to-App.app] short|build
# Default path: dist/Sommelier.app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
usage() { echo "Usage: $(basename "$0") [path-to-App.app] short|build" >&2; exit 1; }
if [ "$#" -eq 2 ]; then APP_BUNDLE="$1"; FIELD="$2"
elif [ "$#" -eq 1 ]; then APP_BUNDLE="${REPO_ROOT}/dist/Sommelier.app"; FIELD="$1"
else usage; fi
case "${FIELD}" in
    short) PLIST_KEY="CFBundleShortVersionString" ;;
    build) PLIST_KEY="CFBundleVersion" ;;
    *) usage ;;
esac
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
[ -f "${INFO_PLIST}" ] || { echo "error: no Info.plist found at ${INFO_PLIST} (build the app first)" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Print :${PLIST_KEY}" "${INFO_PLIST}" 2>/dev/null \
    || { echo "error: key ${PLIST_KEY} missing from ${INFO_PLIST}" >&2; exit 1; }
