.PHONY: build test app run probe dummy dummy-stop clean

APP := build/Sommelier.app
DUMMY := build/MBDummy.app

build:
	swift build

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

probe:
	swift run mbprobe $(ARGS)

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
