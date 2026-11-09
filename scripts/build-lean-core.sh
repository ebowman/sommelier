#!/bin/bash
# Builds build/LeanCore/LeanCore.xcframework: the PROVED Lean decision core (lean/Sommelier/Ffi.lean) compiled to C by the
# pinned Lean toolchain, compiled with its own leanc, and linked with the Lean runtime into one static library.
#
# Usage: scripts/build-lean-core.sh [--force]
# Needs: elan, and the toolchain named in lean/lean-toolchain (see docs/verified-core.md for the pin and upgrade procedure).
# Idempotent: a stamp (hash of lean/**/*.lean, lakefile, manifest, toolchain, shim, Fixture and this script) in build/LeanCore/stamp skips the
# rebuild when nothing changed.  build/ is gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEAN_DIR="${REPO_ROOT}/lean"
OUT="${REPO_ROOT}/build/LeanCore"
XCF="${OUT}/LeanCore.xcframework"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

die() { echo "error: build-lean-core: $*" >&2; exit 1; }

# --- toolchain: elan + the pinned toolchain, never installed behind our back ---
export PATH="${ELAN_HOME:-$HOME/.elan}/bin:$PATH"
command -v elan >/dev/null 2>&1 || die "elan is not installed (looked in ${ELAN_HOME:-$HOME/.elan}/bin and PATH). Install it from https://github.com/leanprover/elan, then run: elan toolchain install \"\$(cat lean/lean-toolchain)\""
[ -f "${LEAN_DIR}/lean-toolchain" ] || die "lean/lean-toolchain is missing"
PIN="$(tr -d '[:space:]' < "${LEAN_DIR}/lean-toolchain")"
TC_NAME="$(printf '%s' "${PIN}" | sed -e 's#/#--#g' -e 's#:#---#g')"
TC="${ELAN_HOME:-$HOME/.elan}/toolchains/${TC_NAME}"
[ -x "${TC}/bin/leanc" ] && [ -x "${TC}/bin/lean" ] || die "the pinned Lean toolchain '${PIN}' is not installed (expected ${TC}). Run: elan toolchain install ${PIN}"
command -v lake >/dev/null 2>&1 || die "lake not found on PATH (it comes with elan)"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (needed for -create-xcframework)"
command -v libtool >/dev/null 2>&1 || die "libtool not found"

# --- stamp ---
HASH="$( { cd "${LEAN_DIR}" && find . -path ./.lake -prune -o -name '*.lean' -print | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done
           cd "${LEAN_DIR}" && shasum -a 256 lakefile.toml lake-manifest.json lean-toolchain shim/sommelier_lean.c shim/sommelier_lean.h
           shasum -a 256 "${SCRIPT_DIR}/build-lean-core.sh"; } | shasum -a 256 | cut -d' ' -f1)"
if [ "${FORCE}" = 0 ] && [ -f "${OUT}/stamp" ] && [ "$(cat "${OUT}/stamp")" = "${HASH}" ] && [ -d "${XCF}" ] && [ -s "${OUT}/fixture.txt" ]; then
    echo "==> LeanCore up to date (${HASH:0:12})"
    exit 0
fi

echo "==> LeanCore: lake build (toolchain ${PIN})"
rm -rf "${OUT}"
mkdir -p "${OUT}/obj" "${OUT}/headers"
( cd "${LEAN_DIR}" && lake build SommelierFfi ) >"${OUT}/lake.log" 2>&1 || { tail -30 "${OUT}/lake.log" >&2; die "lake build SommelierFfi failed (log: ${OUT}/lake.log)"; }

# --- the modules Sommelier.Ffi imports (transitively), from the import lines ---
MODS=""; QUEUE="Ffi"
while [ -n "${QUEUE}" ]; do
    m="${QUEUE%% *}"; if [ "${QUEUE}" = "${m}" ]; then QUEUE=""; else QUEUE="${QUEUE#* }"; fi
    case " ${MODS} " in *" ${m} "*) continue ;; esac
    [ -f "${LEAN_DIR}/Sommelier/${m}.lean" ] || die "module Sommelier.${m} not found"
    MODS="${MODS} ${m}"
    for i in $(sed -n 's/^import Sommelier\.\([A-Za-z0-9_]*\).*/\1/p' "${LEAN_DIR}/Sommelier/${m}.lean"); do QUEUE="${QUEUE} ${i}"; done
    QUEUE="${QUEUE# }"
done
grep -h '^import' $(for m in ${MODS}; do echo "${LEAN_DIR}/Sommelier/${m}.lean"; done) | grep -v '^import Sommelier\.' >/dev/null \
    && die "a linked module imports something outside Sommelier.* (e.g. Std); the static library would need that Lean library too"

CFLAGS="-O3 -DNDEBUG -mmacosx-version-min=26.0 -fvisibility=hidden -I${TC}/include -I${LEAN_DIR}/shim"
echo "==> leanc:${MODS}"
for m in ${MODS}; do
    C="${LEAN_DIR}/.lake/build/ir/Sommelier/${m}.c"
    [ -f "${C}" ] || die "lake produced no ${C}"
    "${TC}/bin/leanc" -c ${CFLAGS} "${C}" -o "${OUT}/obj/${m}.o"
done
xcrun clang -c ${CFLAGS} -fvisibility=default "${LEAN_DIR}/shim/sommelier_lean.c" -o "${OUT}/obj/shim.o"

echo "==> libtool: objects + Init + leanrt + gmp + uv"
for lib in "${TC}/lib/lean/libInit.a" "${TC}/lib/lean/libleanrt.a" "${TC}/lib/libgmp.a" "${TC}/lib/libuv.a"; do
    [ -f "${lib}" ] || die "missing ${lib} in the toolchain"
done
libtool -static -o "${OUT}/libLeanCore.a" "${OUT}"/obj/*.o \
    "${TC}/lib/lean/libInit.a" "${TC}/lib/lean/libleanrt.a" "${TC}/lib/libgmp.a" "${TC}/lib/libuv.a" 2>&1 \
    | grep -v "has no symbols" || true
[ -s "${OUT}/libLeanCore.a" ] || die "libtool produced no library"

cp "${LEAN_DIR}/shim/sommelier_lean.h" "${OUT}/headers/"
cat > "${OUT}/headers/module.modulemap" <<'M'
module LeanCore { header "sommelier_lean.h" export * }
M
xcodebuild -create-xcframework -library "${OUT}/libLeanCore.a" -headers "${OUT}/headers" -output "${XCF}" >/dev/null \
    || die "xcodebuild -create-xcframework failed"
# Expected values for Tests/DecisionCoreTests, computed by the Lean functions themselves (lean/Fixture.lean): named traces + 2000 fuzz traces.
echo "==> fixture: lake exe fixture"
( cd "${LEAN_DIR}" && lake build fixture >>"${OUT}/lake.log" 2>&1 && lake exe fixture 2000 2>>"${OUT}/lake.log" ) >"${OUT}/fixture.txt.tmp" \
    || { tail -30 "${OUT}/lake.log" >&2; die "could not generate the test fixture"; }
mv "${OUT}/fixture.txt.tmp" "${OUT}/fixture.txt"
echo "${HASH}" > "${OUT}/stamp"
echo "==> LeanCore built: $(du -h "${OUT}/libLeanCore.a" | cut -f1) static library, ${XCF}"
