#!/bin/bash
# Takes the Developer ID signed app and DMG through Apple notarization:
# submit, wait, staple, and verify the result satisfies Gatekeeper.
#
# Usage: scripts/notarize-dmg.sh [path-to-dmg]
#   Default: dist/Sommelier-<version>.dmg, version from scripts/read-app-version.sh.
#
# TWO SUBMISSIONS (default mode, no argument), so expect two notarytool waits:
#   1. dist/Sommelier.app (zipped) is notarized and the ticket stapled to the
#      app itself, so a copied app first launched offline still has its ticket.
#   2. The DMG is REBUILT from the stapled app (make-dmg.sh with
#      SKIP_APP_BUILD=1), then notarized and stapled.
# Resumable/idempotent: step 1 is skipped when `stapler validate` already passes
# for the app; everything is skipped when app and DMG both validate and the DMG
# is newer than the app's ticket. If the process dies after step 1, just re-run.
# With an explicit DMG argument only that DMG is notarized (no app step, no rebuild).
#
# WHY: Developer ID signing alone still triggers Gatekeeper warnings for downloaders;
# only a notarized + stapled artifact opens cleanly. The spctl check below is the gate.
#
# CREDENTIALS (never printed or persisted), resolved in order:
#   1. NOTARY_PROFILE env var: keychain profile, via --keychain-profile.
#   2. ./.env (override path with SOMMELIER_ENV_FILE) defining API_KEY_ID and
#      API_ISSUER_ID (an optional leading "export " is fine), plus the key file
#      ~/.appstoreconnect/private_keys/AuthKey_<API_KEY_ID>.p8.
#   3. Neither: exit 1 with setup instructions.
#
# Real network round trip; deliberately no timeout beyond `--wait`.

set -euo pipefail
set +x

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
SCRIPT_DIR="${REPO_ROOT}/scripts"
BUILD_DIR="${REPO_ROOT}/dist"

credentials_missing() {
    cat >&2 <<'MSG'
error: no notarization credentials configured.

Set them up ONE of these two ways:

  1. Keychain profile (store once, then export NOTARY_PROFILE):
       xcrun notarytool store-credentials "SommelierNotary" \
           --key <path-to-AuthKey_XXXX.p8> \
           --key-id <key-id> --issuer <issuer-id>
     Verify with:
       xcrun notarytool history --keychain-profile "SommelierNotary"
     Then run: NOTARY_PROFILE=SommelierNotary make notarize

  2. App Store Connect API key via .env in the repo root (gitignored):
       export API_KEY_ID=<key-id>
       export API_ISSUER_ID=<issuer-id>
     and place the key at:
       ~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8
     (Key and issuer IDs: App Store Connect -> Users and Access ->
     Integrations -> App Store Connect API.)
MSG
    exit 1
}

# Read one variable from an env file without executing it and without
# echoing anything but the value to the caller. Tolerates "export " prefix.
env_value() {
    local key="$1" file="$2" v
    v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -1 \
        | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${key}=//; s/[[:space:]]+$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/")" || true
    printf '%s' "$v"
}

# --- Target resolution ---
APP="${BUILD_DIR}/Sommelier.app"
WITH_APP=1
if [ "$#" -ge 1 ]; then
    DMG="$1"
    WITH_APP=0
else
    [ -d "$APP" ] || { echo "error: ${APP} not found; run make release or pass a DMG path." >&2; exit 1; }
    VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "$APP" short)"
    [ -n "$VERSION" ] || { echo "error: could not read app version." >&2; exit 1; }
    DMG="${BUILD_DIR}/Sommelier-${VERSION}.dmg"
fi
[ -f "$DMG" ] || { echo "error: DMG not found at ${DMG}. Run make release first." >&2; exit 1; }

require_developer_id() {
    local info
    info="$(codesign -dvv "$1" 2>&1 || true)"
    if ! grep -q '^Authority=Developer ID Application' <<<"$info"; then
        echo "error: $1 is not signed with a Developer ID Application identity (ad-hoc or unsigned); it cannot be notarized." >&2
        exit 1
    fi
}
require_developer_id "$DMG"
[ "$WITH_APP" = "1" ] && require_developer_id "$APP"

# --- Credentials ---
AUTH=()
ENV_FILE="${SOMMELIER_ENV_FILE:-${REPO_ROOT}/.env}"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Credentials: keychain profile"
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -f "$ENV_FILE" ]; then
    API_KEY_ID="$(env_value API_KEY_ID "$ENV_FILE")"
    API_ISSUER_ID="$(env_value API_ISSUER_ID "$ENV_FILE")"
    [ -n "$API_KEY_ID" ] && [ -n "$API_ISSUER_ID" ] || credentials_missing
    KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
    if [ ! -f "$KEY_PATH" ]; then
        echo "error: API key file not found at ~/.appstoreconnect/private_keys/AuthKey_<API_KEY_ID>.p8" >&2
        credentials_missing
    fi
    echo "==> Credentials: .env API key"
    AUTH=(--key "$KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID")
else
    credentials_missing
fi

# --- Submit + staple helper ---
mkdir -p "$BUILD_DIR"
SUBMIT_JSON="${BUILD_DIR}/notarize-submit.json"
# submit_and_wait <file>: exits the script unless Apple reports Accepted.
submit_and_wait() {
    local file="$1" id status log
    echo "==> Submitting ${file} (this can take several minutes)..."
    if ! xcrun notarytool submit "$file" --wait --output-format json "${AUTH[@]}" > "$SUBMIT_JSON"; then
        echo "error: notarytool submit failed (see ${SUBMIT_JSON})." >&2
        exit 1
    fi
    id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_JSON")"
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_JSON")"
    echo "==> Submission id: ${id:-<unknown>}"
    echo "==> Status: ${status:-<unknown>}"
    if [ "$status" != "Accepted" ]; then
        echo "error: notarization did not succeed." >&2
        if [ -n "$id" ]; then
            log="${BUILD_DIR}/notarize-log-${id}.json"
            if xcrun notarytool log "$id" "${AUTH[@]}" "$log" >/dev/null 2>&1; then
                echo "==> Log: ${log}" >&2
                python3 -c 'import json,sys
for i in json.load(open(sys.argv[1])).get("issues") or []: print("  -", i.get("severity",""), i.get("path",""), i.get("message",""))' "$log" | head -20 >&2 || true
            else
                echo "error: could not fetch notarization log." >&2
            fi
        fi
        exit 1
    fi
}

dmg_current() {
    xcrun stapler validate "$DMG" >/dev/null 2>&1 && [ "$DMG" -nt "${APP}/Contents/CodeResources" ]
}

# --- Step 1: the app itself ---
if [ "$WITH_APP" = "1" ]; then
    if xcrun stapler validate "$APP" >/dev/null 2>&1; then
        echo "==> ${APP} already has a valid ticket; skipping the app submission."
    else
        ZIP="${BUILD_DIR}/Sommelier-notarize.zip"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        submit_and_wait "$ZIP"
        rm -f "$ZIP"
        echo "==> Stapling the app..."
        xcrun stapler staple "$APP"
    fi
    echo "==> Validating app staple..."
    xcrun stapler validate "$APP"

    if dmg_current; then
        echo "==> ${DMG} is already stapled and built from the stapled app; skipping the DMG submission."
    else
        echo "==> Rebuilding the DMG around the stapled app..."
        SKIP_APP_BUILD=1 "${SCRIPT_DIR}/make-dmg.sh"
        submit_and_wait "$DMG"
    fi
else
    submit_and_wait "$DMG"
fi

# --- Staple + verify the DMG ---
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "==> Stapling the DMG..."
    xcrun stapler staple "$DMG"
fi
echo "==> Validating DMG staple..."
xcrun stapler validate "$DMG"

echo "==> Gatekeeper check (spctl open assessment)..."
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || {
    echo "error: spctl rejected the DMG; release is NOT shippable." >&2
    exit 1
}
if [ "$WITH_APP" = "1" ]; then
    spctl -a -t exec -v "$APP" 2>&1 || {
        echo "error: spctl rejected the app; release is NOT shippable." >&2
        exit 1
    }
    rm -f "$SUBMIT_JSON"
    echo "==> Done: ${APP} and ${DMG} are notarized, stapled, and pass Gatekeeper."
else
    rm -f "$SUBMIT_JSON"
    echo "==> Done: ${DMG} is notarized, stapled, and passes Gatekeeper."
fi
