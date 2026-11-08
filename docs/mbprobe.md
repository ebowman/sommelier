# mbprobe and development notes

`mbprobe` is a command-line tool built from this repository. It is for developers and for debugging: it shows what Sommelier's scanner sees in the menu bar and can change positions and visibility directly. `mbprobe permissions` prints the Accessibility and Screen Recording state.

## mbprobe commands

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

## Developing

`open build/Sommelier.app` goes through LaunchServices; that bundle has no Accessibility grant until a human gives one.
A process started directly from the shell inherits the terminal's Accessibility trust (as `mbprobe` does), so for
development use `make app-run`, which builds the bundle and runs `build/Sommelier.app/Contents/MacOS/Sommelier` in the
background with logs in `build/sommelier.log` (look for `launch trusted=true`). Stop it with `pkill -x Sommelier`.
Live hide/show (cfprefsd-notified `isAllowed` write, no agent respawn) needs the `com.apple.security.application-groups`
entitlement for `group.com.apple.controlcenter` (`Resources/Sommelier.entitlements`). `make build` re-signs the built `mbprobe`
with it; `swift run mbprobe` re-links and runs an UNENTITLED binary, so use `make probe` or `$(swift build --show-bin-path)/mbprobe`.
`mbprobe permissions` prints `live hide/show: available|unavailable`; unentitled binaries use the respawn path automatically.
Debug env vars: `SOMMELIER_DEBUG_MENU=1`, `SOMMELIER_OPEN_SETTINGS=1`, `SOMMELIER_TOGGLE_LOGIN=1`, `SOMMELIER_SHOW_ONBOARDING=1`,
`SOMMELIER_OPEN_ARRANGE=1` (open the Arrange window at launch), and
`SOMMELIER_ARRANGE_MOVE="<storeKey>|<visible|hidden|always>|<index or ->"` (one move through the same code path as a drop, including its clamp, once the
engine has observed; the index is 0-based among MOVABLE items, modules do not count, 0 = first movable slot, 99 = before the trailing
system block; `mbprobe layout move` indexes are 1-based and unclamped; chain moves with `;`, space them with `SOMMELIER_ARRANGE_MOVE_INTERVAL=<seconds>`).
The hook needs no open Arrange window: it resolves capabilities from the engine's items exactly like a drop (`SOMMELIER_OPEN_ARRANGE=1` is only handy to watch the rows).
**`SOMMELIER_LAYOUT_FILE=<path>`** makes the app use that file instead of `~/Library/Application Support/Sommelier/layout.json`:
set it for every development run, so experiments never touch your real layout (the file is created on first launch from the current bar).
