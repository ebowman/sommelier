# Sommelier

Open-source menu bar item manager for macOS 26+ (work in progress).

## Build and test

    make build     # swift build
    make test      # swift test
    make app       # assemble and ad-hoc sign build/Sommelier.app
    make run       # build and open build/Sommelier.app
    make probe ARGS="..."   # swift run mbprobe
    make dummy [ARGS="--count 3 --removal-allowed"]   # build/MBDummy.app test status items
    make dummy-stop
    make clean

Accessibility permission for `build/Sommelier.app` must be granted by the human in
System Settings > Privacy & Security > Accessibility. Ad-hoc re-signing may require re-granting.

The app is deliberately not sandboxed. License: MIT.
