#!/bin/bash
# Tests scripts/publish-release.sh --dry-run refusal and pass paths in a throwaway
# git repo with a fake DMG (real image, fake app Info.plist) and shimmed spctl/xcrun.
# No network, no signing, no changes to this repo. Run: make check-scripts
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/publish-checks.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0

mkdir -p "$T/bin" "$T/bare" "$T/repo/scripts" "$T/stage/Sommelier.app/Contents"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/spctl"; cp "$T/bin/spctl" "$T/bin/xcrun"; chmod +x "$T/bin/spctl" "$T/bin/xcrun"
git init -q --bare "$T/bare"
cp "$SRC/scripts/publish-release.sh" "$T/repo/scripts/"
cd "$T/repo"
git init -q . && git config user.email t@t && git config user.name t
git remote add origin git@github.com:o/r.git
git config "url.$T/bare.insteadOf" git@github.com:o/r.git
echo 0.1.0 > VERSION; git add -A; git commit -qm one
echo x > f; git add f; git commit -qm two      # commit count is now 2

make_dmg() {  # make_dmg <CFBundleVersion> <CFBundleShortVersionString>
    rm -f "$T/repo/dist/Sommelier-0.1.0.dmg"; mkdir -p "$T/repo/dist"
    rm -f "$T/stage/Sommelier.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $1" -c "Add :CFBundleShortVersionString string $2" \
        "$T/stage/Sommelier.app/Contents/Info.plist" >/dev/null
    hdiutil create -quiet -srcfolder "$T/stage" -format UDZO -volname Sommelier "$T/repo/dist/Sommelier-0.1.0.dmg" >/dev/null
}
run() { OUT="$(PATH="$T/bin:$PATH" scripts/publish-release.sh --dry-run 2>&1)"; RC=$?; }
expect() {  # expect <name> <0=must succeed|1=must be refused> <output pattern>
    local ok=0
    if [ "$2" = 0 ]; then [ "$RC" = 0 ] && ok=1; else [ "$RC" != 0 ] && ok=1; fi
    grep -q -- "$3" <<<"$OUT" || ok=0
    if [ "$ok" = 1 ]; then
        PASS=$((PASS+1)); echo "ok   $1"
    else
        FAILS=$((FAILS+1)); echo "FAIL $1 (rc=$RC)"; echo "$OUT" | sed 's/^/     /'
    fi
}

make_dmg 2 0.1.0
run; expect "pass path" 0 "DRY RUN: all checks passed"
grep -q "^sha256: [0-9a-f]\{64\}" <<<"$OUT" && { PASS=$((PASS+1)); echo "ok   prints sha256"; } || { FAILS=$((FAILS+1)); echo "FAIL prints sha256"; }

echo y >> f
run; expect "dirty tracked file refused" 1 "tracked changes"
git checkout -q f
echo zzz > untracked.txt
run; expect "untracked file ignored" 0 "DRY RUN: all checks passed"
rm -f untracked.txt

make_dmg 1 0.1.0
run; expect "stale build number refused" 1 "not built from HEAD"

make_dmg 2 0.2.0
run; expect "version mismatch refused" 1 "CFBundleShortVersionString"

echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
