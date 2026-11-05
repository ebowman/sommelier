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
printf '#!/bin/sh\nexit 0\n' > "$T/bin/spctl"
# xcrun stub: stapler validate on the inner app (path contains Sommelier.app) fails when XCRUN_APP_FAIL=1
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$*" in *Sommelier.app*) exit "${XCRUN_APP_FAIL:-0}";; esac\nexit 0\n' > "$T/bin/xcrun"
chmod +x "$T/bin/spctl" "$T/bin/xcrun"
git init -q --bare "$T/bare"
cp "$SRC/scripts/publish-release.sh" "$T/repo/scripts/"
cd "$T/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git remote add origin git@github.com:o/r.git
git config "url.$T/bare.insteadOf" git@github.com:o/r.git
echo 0.1.0 > VERSION; git add -A; git commit -qm one
echo x > f; git add f; git commit -qm two      # commit count is now 2

make_dmg() {  # make_dmg <CFBundleVersion> <CFBundleShortVersionString> [git sha | none (default HEAD)] [dirty flag (default 0)]
    local sha="${3:-$(git -C "$T/repo" rev-parse HEAD)}" dirty="${4:-0}" extra=()
    [ "$sha" = none ] || extra=(-c "Add :SommelierGitCommit string $sha" -c "Add :SommelierGitDirty string $dirty")
    rm -f "$T/repo/dist/Sommelier-0.1.0.dmg"; mkdir -p "$T/repo/dist"
    rm -f "$T/stage/Sommelier.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $1" -c "Add :CFBundleShortVersionString string $2" ${extra[@]+"${extra[@]}"} \
        "$T/stage/Sommelier.app/Contents/Info.plist" >/dev/null
    hdiutil create -quiet -srcfolder "$T/stage" -format UDZO -volname Sommelier "$T/repo/dist/Sommelier-0.1.0.dmg" >/dev/null
}
mkdir -p "$T/tmp"
run() { OUT="$(TMPDIR="$T/tmp" PATH="$T/bin:$PATH" scripts/publish-release.sh --dry-run 2>&1)"; RC=$?; }
expect() {  # expect <name> <0=must succeed|1=must be refused> <output pattern>
    local ok=0
    if [ "$2" = 0 ]; then [ "$RC" = 0 ] && ok=1; else [ "$RC" != 0 ] && ok=1; fi
    grep -q -- "$3" <<<"$OUT" || ok=0
    if [ "$ok" = 1 ]; then
        PASS=$((PASS+1)); echo "ok   $1"
    else
        FAILS=$((FAILS+1)); echo "FAIL $1 (rc=$RC)"; printf '     %s\n' "${OUT//$'\n'/$'\n     '}"
    fi
}

make_dmg 2 0.1.0
run; expect "pass path" 0 "DRY RUN: all checks passed"
expect "prints sha256" 0 "^sha256: [0-9a-f]\{64\}"

echo y >> f
run; expect "dirty tracked file refused" 1 "tracked changes"
git checkout -q f
echo zzz > untracked.txt
run; expect "untracked file ignored" 0 "DRY RUN: all checks passed"
rm -f untracked.txt

make_dmg 1 0.1.0
run; expect "stale build number refused" 1 "not built from HEAD"

make_dmg 2 0.1.0 0123456789abcdef0123456789abcdef01234567
run; expect "SHA mismatch (same count) refused" 1 "embedded git commit"

make_dmg 2 0.1.0 "$(git rev-parse HEAD)" 1
run; expect "dirty-flag DMG refused" 1 "dirty tree"

make_dmg 2 0.1.0 none
run; expect "DMG without SHA key refused" 1 "predates the SHA check"

make_dmg 2 0.1.0
XCRUN_APP_FAIL=1 run; expect "inner app stapler failure refused" 1 "app inside"

if compgen -G "$T/tmp/sommelier-notes.*" >/dev/null; then
    FAILS=$((FAILS+1)); echo "FAIL dry-run left a notes file"
else
    PASS=$((PASS+1)); echo "ok   no notes file left"
fi

make_dmg 2 0.2.0
run; expect "version mismatch refused" 1 "CFBundleShortVersionString"

echo "$PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
