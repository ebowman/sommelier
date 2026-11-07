# Sommelier

An open-source menu bar item manager for macOS 26+, built as a Bartender alternative that does not lie.

**Sommelier decides what shows in your menu bar and in what order. Arrange items in the window; the bar follows. System
items at the right end stay where macOS puts them.** Everything in Visible is in order, including what macOS hides behind
the « chevron; Sommelier opens the « strip for a moment when it has to move something across that fold.

Hidden items are one click away in an overflow panel, with quick toggles. The Arrange window is the record of your menu bar:
what it says is what Sommelier makes the real bar do, and what the real bar does is shown next to it, never the other way round.

Bartender's recurring failure mode is that it says it moved or hid an item and the item did not move, or the
order silently changed. Sommelier is built around one rule: **nothing is shown as done until the real menu bar
confirms it.** The strip shows what you asked for (the record); each row's badge shows what the bar actually does.

![The overflow panel listing the hidden items, Dummy A and Dummy B first](docs/images/panel.png)

*The overflow panel opens under the menu bar and lists the hidden items.*

![The Arrange window with the Visible, Hidden and Always hidden sections](docs/images/arrange.png)

*The Arrange window: Visible, Hidden and Always hidden, each item badged with its observed state.*

## Status

Alpha (0.1.x). macOS 26 or later only. Developed and tested on macOS 27.0.1 (Xcode 27.1, Swift 6.4); macOS 26 is
assumed to behave the same but has not been verified. Single display only; multi-display is untested.

Logs: `~/Library/Logs/Sommelier/sommelier.log` (also in the unified log, subsystem `ie.boboco.sommelier`; status item menu, Open Log Folder).

## Requirements

- macOS 26 or later.
- **Accessibility permission (required).** Sommelier reads and arranges items through the Accessibility API.
- Screen Recording is **not** required. It only enables live item images in the overflow panel, and denying it is not an error.
- Sommelier is deliberately not sandboxed.

## Install

Before you start: quit Bartender (or any other menu bar manager). The engine pauses while another manager runs, because they fight each other.

1. Download `Sommelier-<version>.dmg` from the GitHub Releases page. It is signed with a Developer ID and notarized by Apple.
2. Open the DMG and drag Sommelier to Applications.
3. Launch it from Applications. macOS shows the usual "downloaded from the internet" confirmation; click Open.
4. Sommelier opens an onboarding window until Accessibility is granted. Grant it in System Settings > Privacy & Security >
   Accessibility (on macOS 27 the pane is called "Device Control and Data Access"). It starts working without a relaunch.

## Usage

- **Left-click** the Sommelier menu bar item: opens the overflow panel listing the hidden items. Click an entry to open
  that item's real menu; the item is hidden again after the menu closes.
- **Right-click** menu: Arrange..., Settings..., Start at login, Quit.
- **Arrange window**: three strips, Visible, Hidden and Always hidden. The Visible strip is the record, in order: drag a capsule
  anywhere in Visible and the bar follows; drag it across strips to hide, show or always hide it. Each capsule has a badge for the
  state of the real bar (hover for the plain-words reason; "Try again" is in the context menu of a row that could not be placed):
  - check: the real bar matches the record for this row;
  - arrows: Sommelier is moving it, or the bar does not agree yet;
  - warning: Sommelier could not place it (failed, unsupported, or it gave up after three attempts);
  - dashed circle: the item is not on the bar right now; this is where it is going;
  - tilde: its position is being re-read;
  - «: macOS hides it behind its own overflow chevron because the bar is full; a fold line marks the boundary;
  - hourglass: you moved it by hand in the menu bar and its new position is not read yet;
  - no badge: drawn, but not confirmed in place yet (the tooltip says so).

  While Sommelier moves an item the status line says which ("Moving X…") and a small floating notice asks you to keep your hands
  off the mouse (Settings: "Show a notice while Sommelier moves the mouse"). The status line reads "Menu bar matches" only when every
  row is a check, behind the «, or not on the bar.
- **Spacing**: Settings > Spacing sets the two global menu bar spacing values (`NSStatusItemSpacing` and `NSStatusItemSelectionPadding`, 0 to 24,
  saved when you release the slider or press Return). A change applies when each app is relaunched (no logout needed); "Reset to system default"
  removes both values. The same from a terminal: `mbprobe spacing get|set|reset`. Details: [docs/findings-spacing.md](docs/findings-spacing.md).
- **Always hidden**: items placed there stay hidden, including when the Hidden section is revealed.
- **Hide what does not fit...**: a manual button in the Arrange window toolbar, enabled only when items sit behind macOS's
  overflow chevron (a crowded bar, for example on a notched display). It opens a confirmation sheet and then hides those items
  so you can reach them from the panel instead. Sommelier never hides anything automatically.
- **Per-app caveat**: macOS hides all status items of one app together. If an app has two items, they share one visibility setting.

## How it works

- **The record.** The Visible list in Arrange (stored in `layout.json`) is the order of your menu bar, left to right. Sommelier plans
  moves from it, one at a time, and re-reads the real bar after each. Items in the system block at the right end (Control Center,
  clock, ...) are macOS's and are never moved.
- **The strip is the record; badges are the bar.** The strip never reorders itself to match the bar. If the bar disagrees, the
  row's badge says so (moving, cannot place, behind «, being re-read) until the bar has confirmed the change.
- **Behind the « chevron.** When the bar is full macOS folds the leftmost items behind « and draws them stacked, so their order
  cannot be read there. Everything in Visible is still in order: when Sommelier has to move something across that fold it opens the
  « strip for a moment (one open and one close per crossing), moves the item with the real items drawn, and closes it again. It
  never opens the strip just to look, and the order among items that stay behind « is not tracked while the strip is closed.
- **Your own changes are adopted, not undone.** A Command-drag you do by hand in the menu bar becomes the new record; Sommelier
  never moves it back. An item you hide in System Settings > Menu Bar moves to Hidden ("Moved X to Hidden: it is hidden in System
  Settings"). A layout saved by an older version is adopted from the bar as it is, with nothing moved.
- **Hiding and showing** is done live through the Control Center preference domain (the per-app "Allow in the Menu Bar" flag),
  notified through cfprefsd without restarting the agent; this needs the `group.com.apple.controlcenter` app-group entitlement, which
  the release build carries. Every change is re-observed and compared with the intended state (closed loop) before the UI marks it done.
- **Scanning** reads the Accessibility tree hosted by macOS's `MenuBarAgent` process (menu bar items are no longer separate per-app
  windows on macOS 26+) and each app's `AXExtrasMenuBar`.
- **Safety envelope.** Ordering uses real mouse events (a Command-drag), so it is bounded: one move per pass and a fresh read after
  it; at most 6 moves per minute (then a one-minute pause for ordering only); an item that takes 3 order moves within 10 minutes is
  given up on ("can't be placed", kept where it is) until you press Try again, its app relaunches or you edit it; nothing moves while a
  menu is open, a mouse button or modifier key is down, you are dragging in the menu bar or in Arrange, or the screen is locked (the
  engine waits 3 s, then pauses and retries after 2 s, doubling to 60 s; unlocking resumes at once). "Pause Sommelier" in the
  status item menu stops all moves until you resume. A failure is surfaced, never swallowed.

The design, the actuator strategy and the measurements behind it are in [docs/architecture.md](docs/architecture.md) and the
findings: [positioning](docs/findings-positioning.md), [visibility](docs/findings-visibility.md),
[live trigger](docs/findings-live-trigger.md), [drag](docs/findings-drag.md), [identity](docs/findings-identity.md),
[preference store](docs/findings-prefstore.md), [restart collateral](docs/findings-restart-collateral.md).

What macOS also does by itself, with or without Sommelier: Command-drag reorders in the menu bar, System Settings > Menu Bar
switches show or hide items, and the overflow chevron holds the items that do not fit.

## Known limitations

- System items at the right end (Control Center, the clock) stay where macOS puts them; nothing can be placed right of them.
- Apple apps' items cannot be hidden.
- Apps without a "Allow in the Menu Bar" entry in Control Center cannot be hidden yet.
- Reordering takes about 6-11 s per item because it uses real drags and moves the real mouse (a move across the « fold adds the strip open and close); hide/show takes 1-5 s, bounded by scan time. Moves are limited to one per pass and 6 per minute.
- Order is not tracked among items behind the « chevron while the strip is closed.
- Items that macOS has pushed behind its « chevron are reached by opening the strip; "Hide what does not fit..." in the Arrange window is a manual action and never runs automatically.
- Multi-display is untested.
- macOS 15 and earlier are not supported.
- Rebuilding from source changes the ad-hoc signature, so Accessibility must be granted again (see Troubleshooting).
  The notarized release keeps a stable identity across versions.

## Troubleshooting

- Not working after a rebuild, or Accessibility looks granted but is not effective:
  `tccutil reset Accessibility ie.boboco.sommelier`, relaunch, and grant again.
- `mbprobe list` prints what the scanner sees (use `make probe ARGS="list"` from a source checkout);
  `mbprobe permissions` prints the Accessibility and Screen Recording state and `live hide/show: available|unavailable`.
- Logs: a development run (`make app-run`) writes `build/sommelier.log`; look for `launch trusted=true`.
- The engine does nothing while Bartender is running; quit it.

## Building from source

    make build     # swift build
    make test      # swift test
    make app       # assemble and ad-hoc sign build/Sommelier.app
    make run       # build and open build/Sommelier.app (no Accessibility trust; prefer app-run)
    make app-run   # run the bundle binary directly so it inherits the terminal's Accessibility trust
    make release VERSION=x.y.z   # Developer ID signed + DMG in dist/ (see CONTRIBUTING.md)
    make probe ARGS="..."   # build (signs mbprobe with the app-group entitlement), then run the bin-path mbprobe
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

## Permissions (reference)

- **Accessibility (required)**: System Settings > Privacy & Security > Accessibility
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`).
- **Screen Recording (optional)**: live item images in the overflow panel
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`).
- `SOMMELIER_SHOW_ONBOARDING=1` forces the onboarding window at launch.

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

## License

MIT, Copyright (c) 2026 Eric Bowman. See [LICENSE](LICENSE). Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).
