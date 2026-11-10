.PHONY: lean-core verify-core build test app run app-run probe dummy dummy-stop clean release notarize publish check-scripts

APP := build/Sommelier.app
DUMMY := build/MBDummy.app

# build also re-signs mbprobe ad-hoc with the app-group entitlement (live hide/show); `swift run` would re-link it unsigned.
# The proved Lean decision core (static library + xcframework in build/LeanCore, gitignored); a no-op when lean/ is unchanged.
lean-core:
	scripts/build-lean-core.sh

# SwiftPM caches the evaluated Package.swift by its text and environment, not by whether build/LeanCore exists; the stamp in the environment
# makes it re-evaluate whenever the core changes. (After deleting build/LeanCore, a plain `swift build` can still see the old answer: `swift package purge-cache`.)
export SOMMELIER_LEANCORE_STAMP = $(shell cat build/LeanCore/stamp 2>/dev/null || echo none)

# Every check on the proved core, fail-fast, one line per step (MUTANTS=full adds the ~45 min mutant run). See docs/verified-core.md.
verify-core:
	scripts/verify-core.sh

build: lean-core
	swift build
	codesign --force --sign - --entitlements Resources/Sommelier.entitlements "$$(swift build --show-bin-path)/mbprobe"

# The ReadAdapter property test (AdapterPropertyTests, ~1 s of CPU) runs in its OWN invocation after the main suite, never concurrently with the
# timing-sensitive engine tests (it starved Gdu126 / Gdu144Adversarial when they shared a run). Plain `swift test` runs both targets, one after the other.
test: lean-core
	scripts/check-single-decider.sh
	swift test --skip AdapterPropertyTests
	swift test --filter AdapterPropertyTests

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build --show-bin-path)/Sommelier" $(APP)/Contents/MacOS/Sommelier
	/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ie.boboco.sommelier' \
	  -c 'Add :CFBundleName string Sommelier' \
	  -c 'Add :CFBundleExecutable string Sommelier' \
	  -c 'Add :CFBundlePackageType string APPL' \
	  -c 'Add :CFBundleVersion string 1' \
	  -c 'Add :CFBundleShortVersionString string 0.1' \
	  -c 'Add :LSUIElement bool true' \
	  -c 'Add :LSMinimumSystemVersion string 26.0' \
	  -c 'Add :NSAccessibilityUsageDescription string Sommelier uses Accessibility to read and arrange menu bar items.' \
	  -c 'Add :NSScreenCaptureUsageDescription string Sommelier may capture the menu bar to show hidden items.' \
	  $(APP)/Contents/Info.plist
	codesign --force --sign - --entitlements Resources/Sommelier.entitlements $(APP)

run: app
	open $(APP)

# Development: run the binary directly so it inherits the terminal's Accessibility trust (see README).
app-run: app
	-@pkill -x Sommelier || true
	$(APP)/Contents/MacOS/Sommelier > build/sommelier.log 2>&1 &

probe: build
	"$$(swift build --show-bin-path)/mbprobe" $(ARGS)

dummy: build
	rm -rf $(DUMMY)
	mkdir -p $(DUMMY)/Contents/MacOS
	cp "$$(swift build --show-bin-path)/mbdummy" $(DUMMY)/Contents/MacOS/MBDummy
	/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string ie.boboco.mbdummy' \
	  -c 'Add :CFBundleName string MBDummy' \
	  -c 'Add :CFBundleExecutable string MBDummy' \
	  -c 'Add :CFBundlePackageType string APPL' \
	  -c 'Add :LSUIElement bool true' \
	  -c 'Add :LSMinimumSystemVersion string 26.0' \
	  $(DUMMY)/Contents/Info.plist
	codesign --force --sign - $(DUMMY)
	open $(DUMMY) $(if $(ARGS),--args $(ARGS),)

dummy-stop:
	-osascript -e 'quit app id "ie.boboco.mbdummy"'
	-@sleep 1; pkill -x MBDummy || true

clean:
	-swift package clean   # the manifest refuses to load without build/LeanCore (see Package.swift): clean must still remove build/
	rm -rf build

# Release pipeline (Developer ID, hardened runtime, notarized, stapled DMG). See CONTRIBUTING.md.
# VERSION defaults to the VERSION file; override with `make release VERSION=x.y.z`.
# A rebuild invalidates any previous notarization, so stale artefacts of it are removed first.
release:
	rm -f dist/notarize-submit.json dist/notarize-log-*.json dist/Sommelier-notarize.zip dist/*.dmg.sha256 dist/release-notes.md
	scripts/make-dmg.sh
	@v="$$(scripts/read-app-version.sh short)"; \
	  echo "==> dist/Sommelier-$$v.dmg"; shasum -a 256 "dist/Sommelier-$$v.dmg"

notarize:
	scripts/notarize-dmg.sh

# OPERATOR-INVOKED ONLY: creates a real public GitHub release. Refuses unless CONFIRM_PUBLISH=1.
publish:
	@[ "$$CONFIRM_PUBLISH" = "1" ] || { echo "refusing: run CONFIRM_PUBLISH=1 make publish"; exit 1; }
	scripts/publish-release.sh

# Shell tests for the release scripts (no network, no signing).
check-scripts:
	scripts/tests/publish-checks.sh
