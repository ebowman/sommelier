.PHONY: build test app run app-run probe dummy dummy-stop clean

APP := build/Sommelier.app
DUMMY := build/MBDummy.app

# build also re-signs mbprobe ad-hoc with the app-group entitlement (live hide/show); `swift run` would re-link it unsigned.
build:
	swift build
	codesign --force --sign - --entitlements Resources/Sommelier.entitlements "$$(swift build --show-bin-path)/mbprobe"

test:
	swift test

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
	swift package clean
	rm -rf build
