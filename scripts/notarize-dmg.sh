#!/bin/bash
# Takes a Developer ID signed DMG through Apple notarization: submit, wait,
# staple, and verify the result satisfies Gatekeeper.
#
# Usage: scripts/notarize-dmg.sh [path-to-dmg]
#   Default: dist/Sommelier-<version>.dmg, version from scripts/read-app-version.sh.
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

# --- DMG path ---
if [ "$#" -ge 1 ]; then
    DMG="$1"
else
    APP="${BUILD_DIR}/Sommelier.app"
    [ -d "$APP" ] || { echo "error: ${APP} not found; run make dmg or pass a DMG path." >&2; exit 1; }
    VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "$APP" short)"
    [ -n "$VERSION" ] || { echo "error: could not read app version." >&2; exit 1; }
    DMG="${BUILD_DIR}/Sommelier-${VERSION}.dmg"
fi
[ -f "$DMG" ] || { echo "error: DMG not found at ${DMG}. Run make dmg first." >&2; exit 1; }

SIGINFO="$(codesign -dvv "$DMG" 2>&1 || true)"
if ! grep -q '^Authority=Developer ID Application' <<<"$SIGINFO"; then
    echo "error: ${DMG} is not signed with a Developer ID Application identity (ad-hoc or unsigned); it cannot be notarized." >&2
    exit 1
fi

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

# --- Submit ---
mkdir -p "$BUILD_DIR"
SUBMIT_JSON="${BUILD_DIR}/notarize-submit.json"
echo "==> Submitting ${DMG} (this can take several minutes)..."
if ! xcrun notarytool submit "$DMG" --wait --output-format json "${AUTH[@]}" > "$SUBMIT_JSON"; then
    echo "error: notarytool submit failed (see ${SUBMIT_JSON})." >&2
    exit 1
fi

ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_JSON")"
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_JSON")"
echo "==> Submission id: ${ID:-<unknown>}"
echo "==> Status: ${STATUS:-<unknown>}"

if [ "$STATUS" != "Accepted" ]; then
    echo "error: notarization did not succeed." >&2
    if [ -n "$ID" ]; then
        LOG="${BUILD_DIR}/notarize-log-${ID}.json"
        if xcrun notarytool log "$ID" "${AUTH[@]}" "$LOG" >/dev/null 2>&1; then
            echo "==> Log: ${LOG}" >&2
            python3 -c 'import json,sys
for i in json.load(open(sys.argv[1])).get("issues") or []: print("  -", i.get("severity",""), i.get("path",""), i.get("message",""))' "$LOG" | head -20 >&2 || true
        else
            echo "error: could not fetch notarization log." >&2
        fi
    fi
    exit 1
fi

# --- Staple + verify ---
echo "==> Stapling..."
xcrun stapler staple "$DMG"
echo "==> Validating staple..."
xcrun stapler validate "$DMG"

echo "==> Gatekeeper check (spctl open assessment)..."
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || {
    echo "error: spctl rejected the DMG; release is NOT shippable." >&2
    exit 1
}
echo "==> Done: ${DMG} is notarized, stapled, and passes Gatekeeper."
