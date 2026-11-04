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

## mbprobe

    mbprobe list [--json] [--include-self] [--timing] [--debug]
    mbprobe set-position <bundleID> <autosaveName> <number> [--host] [--store legacy|agent]
        legacy (default): writes `NSStatusItem Preferred Position <autosave>` into the app's defaults domain
        (CFPreferences; --host = current host). Has no observable effect on macOS 26+/27.
        agent: edits `TrailingItemPreferredPositions` key `status:<bundleID>::<autosave>` in the MenuBarAgent
        group-container plist (atomic write). Takes effect after `mbprobe agent-restart`. Larger = further left.
    mbprobe watch [--seconds N]     poll the scanner every ~2 s, print order diffs (default 60 s)
    mbprobe agent-restart           killall MenuBarAgent, wait until the hosted item count recovers (10 s timeout), print elapsed ms
    mbprobe cc-allowed list         every tracked app with its "Allow in the Menu Bar" flag (1/0) from the Control Center plist
    mbprobe cc-allowed set <appKey> <0|1> [--restart] [--create] [--restart-cc]
        edits `isAllowed` inside the `trackedApplications` blob of group.com.apple.controlcenter.plist (atomic write, mode kept).
        appKey = bundle id (or the file URL for adhocBinary entries). Unknown keys are refused unless --create; `module:` and
        `com.apple.*` are always refused. 0 = hidden (parked), 1 = shown. Takes effect after `--restart` (killall MenuBarAgent);
        --restart-cc (kill system ControlCenter only) does NOT apply it.
    mbprobe set-visible <bundleID> <autosaveName> <0|1> [--host]
        legacy `NSStatusItem Visible <autosave>` write. Only honored when the owning app (re)launches; see docs/findings-visibility.md.
    mbprobe press <bundleID-or-key> [--escape-after SECONDS]
        AXPress on an app-side AXMenuExtra (works on parked items), prints resulting AXMenu/AXPopover child and windows.

See docs/findings-positioning.md and docs/findings-visibility.md.

## Permissions

- **Accessibility (required)**: needed to read and arrange menu bar items. Grant it in System Settings > Privacy & Security > Accessibility
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`). Sommelier opens an onboarding window until it is granted,
  and starts working without relaunch once it is.
- **Screen Recording (optional)**: only enables live item images in the overflow panel
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`). Denied is not an error.
- After rebuilding, the ad-hoc signature changes and macOS may require granting again. Fix:
  `tccutil reset Accessibility ie.boboco.sommelier`, relaunch, and re-grant.
- `mbprobe permissions [--prompt]` prints both states. `SOMMELIER_SHOW_ONBOARDING=1` forces the onboarding window at launch.

The app is deliberately not sandboxed. License: MIT.
