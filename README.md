# Sommelier

Sommelier is a free, open-source menu bar manager for macOS 26 and later. It decides which menu bar items show and in what
order, and keeps the rest one click away in a panel. It is notarized by Apple and released under the MIT license.

You arrange items in a window and the real menu bar follows. System items at the right end (Control Center, the clock) stay
where macOS puts them. Sommelier does not show a change as done until it has looked at the real menu bar and seen the change there.

![The overflow panel listing the hidden items, Dummy A and Dummy B first](docs/images/panel.png)

*The overflow panel opens under the menu bar and lists the items you have hidden. Click one to open its menu.*

![The Arrange window with the Visible, Hidden and Always hidden sections](docs/images/arrange.png)

*The Arrange window. Drag items between Visible, Hidden and Always hidden. Each item shows a badge for what the real bar is doing.*

## Why is this hard on macOS?

If a menu bar manager ever told you an item was hidden and it was still there, or put your icons back in a different order, this is why.

- Since macOS 26, the menu bar items are not drawn by the apps. A system process called `MenuBarAgent` hosts them.
- macOS has no public way for an app to reorder or hide another app's menu bar items. You can Command-drag an icon by hand,
  or switch an app off in System Settings > Menu Bar. That is all the system offers.
- When the bar is full, macOS folds the items that do not fit behind a « chevron. macOS decides what folds, based on width. An app cannot choose.
- Some apps move their own items. iStat Menus is one example.

So a tool that manages the bar has to watch it from outside, through the Accessibility interface. Then it nudges the bar
with synthetic mouse drags and by changing the same setting System Settings uses. The bar can disagree a second later. Another app
moves, the chevron folds something, or a drag lands in the wrong place. The gap between "I moved it" and "it moved" is where a tool can
tell you something that is not true.

## What Sommelier does differently

This is a different approach. It does not claim to make macOS do what macOS does not allow.

- **One list of what you want.** The Visible list in the Arrange window is your menu bar, left to right. Sommelier plans every
  move from it. It never reorders the list to match the bar.
- **Nothing is done until it is seen.** After each change Sommelier re-reads the real bar and compares. We have not seen another
  tool that refuses to show a change as done until the bar confirms it.
- **Every row shows the bar's real state.** The badge says whether the item is on the bar, behind the «, being moved, could not be
  placed, or not confirmed yet. The window cannot show a checkmark for something the bar did not do.
- **One careful move at a time.** Moving an item uses a real Command-drag, so it is limited: one move, then a fresh read. At most
  6 moves a minute. An item that keeps failing is given up on and marked, until you press Try again. Nothing moves while a menu is open,
  a mouse button or modifier key is down, you are dragging, or the screen is locked.
- **Your own changes are adopted, not undone.** If you Command-drag an icon by hand, or hide an app in System Settings, Sommelier
  takes that as your new wish. It does not move it back.
- **Items behind the « are ordered too.** Their order cannot be read while they are folded. When Sommelier has to move something
  across the fold, it opens the « area for a moment, moves the item while the real icons are drawn, and closes it again.

What it cannot do:

- Hide Apple's own items, or place anything to the right of the system items.
- Reorder an item that its own app keeps repositioning.
- Act while a menu is open. It waits.
- Make macOS stop folding items when the bar is full. It can hide items you choose, so the rest fit.

## Coming from Bartender

1. Quit Bartender before you start Sommelier. Two managers fight each other, so Sommelier pauses while Bartender runs.
2. Items Bartender hid are normally hidden through macOS's own per-app switch. Sommelier's first layout is built from the bar as it is now:
   visible items stay visible, and items hidden through macOS's switch are adopted as hidden.
3. Sommelier does less on purpose. It handles show, hide and order, an overflow panel for hidden items, and menu bar spacing. It has
   nothing else, such as themes, triggers or search.
4. To go back, quit Sommelier and start Bartender. Items Sommelier hid stay switched off in System Settings > Menu Bar until you turn
   them on there or move them to Visible in Sommelier.

## Requirements

- macOS 26 or later. Developed and tested on macOS 27.0.1; macOS 26 is assumed to behave the same but has not been verified.
- Single display. Multiple displays are untested.
- **Accessibility permission (required).** Sommelier needs it to read the menu bar and to move items with the mouse.
- **Control Center data access (required).** macOS calls it "App Data" or "access data from other apps". Sommelier needs it to read
  Control Center's list of hidden items. Without it Sommelier cannot tell hidden items from visible ones, so it will not move or hide anything.
- Screen Recording is optional. It only adds live item images to the overflow panel. Denying it is not an error.
- Sommelier is deliberately not sandboxed.

## Install

1. Download `Sommelier-<version>.dmg` from the [GitHub releases page](https://github.com/ebowman/sommelier/releases). A `.sha256` file
   sits next to the DMG on the release page. The app is signed with a Developer ID and notarized by Apple.
2. Open the DMG and drag Sommelier to Applications.
3. Launch it. macOS shows the usual "downloaded from the internet" prompt. Click Open.
4. Grant Accessibility in System Settings > Privacy & Security > Accessibility (on macOS 27 the pane is called "Device Control and
   Data Access"). An onboarding window stays until you do. Sommelier starts working without a relaunch.
5. Control Center data access is also needed, and it is checked on every scan, not only when you first hide something. If macOS denies
   it, Sommelier stops moving and hiding. macOS often does not show a prompt for it. If the onboarding window says "Access denied",
   use the status menu's "Permissions..." (or "Grant Control Center data access...") item, or look for Sommelier under System Settings >
   Privacy & Security. See Troubleshooting if it is not listed.

Alpha software (0.1.x). Please expect rough edges.

## Usage

- **Left-click** the Sommelier menu bar item to open the overflow panel. Click an entry to open that item's menu. The item is hidden again after the menu closes.
- **Right-click** for a menu that includes Show hidden items, Pause Sommelier (it reads Resume Sommelier while paused), Arrange...,
  Settings..., Start at login, Permissions..., Open Log Folder and Quit.
- **Arrange window.** Three sections: Visible, Hidden and Always hidden. Drag an item anywhere in Visible and the bar follows. Drag it
  across sections to hide or show it. Items in Always hidden stay hidden even when Hidden is revealed. Hover a badge for the reason.
  - check: the bar matches your list for this item;
  - arrows: Sommelier is moving it, or the bar does not agree yet;
  - warning: Sommelier could not place it. Use "Try again" in the row's context menu;
  - dashed circle: the item is not on the bar right now; this is where it will go;
  - tilde: its position is being re-read;
  - «: macOS folded it behind its chevron because the bar is full. A fold line marks the edge;
  - hourglass: you moved it by hand and its new position is not read yet;
  - faded check with a small orange dot: applied, waiting for the bar to confirm;
  - no-sign symbol: Sommelier cannot change this item (Apple's own items, for example);
  - no badge: drawn, but not confirmed in place yet.

  While an item moves, the status line names it and a small notice asks you to keep your hands off the mouse. You can turn the
  notice off in Settings. The status line says "Menu bar matches" only when every row is confirmed, behind the «, or not on the bar.
- **Spacing.** Settings > Spacing sets the two global menu bar spacing values (0 to 24). Apps pick up a change when they relaunch.
  "Reset to system default" removes both. Details: [docs/findings-spacing.md](docs/findings-spacing.md).
- **Hide what does not fit...** A button in the Arrange window toolbar, enabled only when items sit behind the «. It asks first, then hides
  those items so you can reach them from the panel. Sommelier never does this on its own.
- **One setting per app.** macOS hides all status items of one app together, so an app with two items has one visibility setting.

## Known limitations

- System items at the right end stay where macOS puts them.
- Apple apps' items cannot be hidden.
- Apps with no "Allow in the Menu Bar" entry in Control Center cannot be hidden yet.
- Reordering takes about 6 to 11 seconds per item because it uses real drags and moves your mouse. Hide and show take 1 to 5 seconds.
- Order among items behind the « is not tracked while that area is closed.
- If more items are Visible than fit on your bar, macOS decides what folds behind «, and Sommelier does not fight it. It keeps the order among the items that are drawn, and it never pulls a folded item out on its own. It crosses the fold only when you drop a folded item to the right of the fold line in Arrange, and then it tries once. If you drop one to the left of the fold line, your order is saved and the item stays behind « until there is room. If any drag Sommelier starts on its own fails, it stops moving things on its own until you press Re-apply layout, drag an item yourself, or Sommelier has seen a bar with no « for a while (about half a minute of quiet checks), and the status line says the bar is full. The way out is to hide items you do not need ("Hide what does not fit" in Arrange).
- Multiple displays are untested. macOS 15 and earlier are not supported.
- Rebuilding from source changes the ad-hoc signature, so Accessibility must be granted again. The notarized release keeps a stable identity.

## Troubleshooting

- Accessibility looks granted but nothing happens, or after a rebuild: run `tccutil reset Accessibility ie.boboco.sommelier`, relaunch and grant again.
- Sommelier says "Access denied" for Control Center data, or nothing moves or hides: quit Sommelier, run
  `tccutil reset SystemPolicyAppData ie.boboco.sommelier` in Terminal, and relaunch. The status menu also shows
  "Grant Control Center data access..." while access is denied.
- Nothing moves: check that Bartender or another menu bar manager is not running.
- Logs are in `~/Library/Logs/Sommelier/sommelier.log` (also the unified log, subsystem `ie.boboco.sommelier`). The status item menu has Open Log Folder.
- `mbprobe list` prints what the scanner sees. See [docs/mbprobe.md](docs/mbprobe.md).

## How it works, in depth

[docs/architecture.md](docs/architecture.md) has the design. The measurements behind it are in the findings:
[positioning](docs/findings-positioning.md), [visibility](docs/findings-visibility.md),
[live trigger](docs/findings-live-trigger.md), [drag](docs/findings-drag.md), [identity](docs/findings-identity.md),
[preference store](docs/findings-prefstore.md), [restart side effects](docs/findings-restart-collateral.md),
[attribution](docs/findings-attribution.md), [hiding untracked items](docs/findings-untracked-hide.md).

## Building from source

    make build     # swift build
    make test      # swift test
    make app       # assemble and ad-hoc sign build/Sommelier.app
    make app-run   # run the bundle binary directly so it inherits the terminal's Accessibility trust
    make release VERSION=x.y.z   # Developer ID signed + DMG in dist/ (see CONTRIBUTING.md)
    make probe ARGS="..."   # build, then run the mbprobe command-line tool
    make dummy [ARGS="--count 3 --removal-allowed"]   # test status items
    make dummy-stop
    make clean

## Developing

`mbprobe` is a command-line inspection tool. Its commands, the debug environment variables and development notes are in
[docs/mbprobe.md](docs/mbprobe.md). Set `SOMMELIER_LAYOUT_FILE=<path>` for every development run so experiments never touch your real layout.
Test notes: [docs/testing.md](docs/testing.md).

## License

MIT, Copyright (c) 2026 Eric Bowman. See [LICENSE](LICENSE). Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).
