# Manual testing

## Developer launch trick
Run the app binary from a shell that has Accessibility trust, not via `open`:

    make app-run                         # logs to build/sommelier.log
    SOMMELIER_OPEN_PANEL=1 make app-run  # also opens the overflow panel 3 s after launch and logs its frame + entries
    pkill -x Sommelier

The engine pauses while Bartender runs, so quit Bartender first (`osascript -e 'quit app "Bartender 7"'`) or the
panel has no observed state. Relaunch it afterwards (`open -a "Bartender 7"`). A first launch creates
`~/Library/Application Support/Sommelier/layout.json`; delete it (and `.bak`) to start fresh.

## Overflow panel
1. Open: left-click the Sommelier item (Settings > General > Reveal mode = "Panel below menu bar"). A panel appears
   directly under the menu bar, right edge under the item, listing each hidden item as app icon plus name. The
   frontmost app must keep focus (no activation).
2. Close rules: click anywhere outside the panel; press Escape (closes the panel whenever it is open; the frontmost app is not activated); leave the union of
   panel and menu bar strip with the pointer for 400 ms; or stay idle for "Auto re-hide" seconds (0 = never).
   Clicking the Sommelier item again toggles it closed.
3. Show names off: Settings > "Show names in panel" shows icons only; hover shows the name as tooltip.
4. Many items: when the row is wider than 80 % of the screen it scrolls horizontally.
5. Empty state: with nothing hidden (or no hidden app running) the panel reads "Nothing hidden" with a disabled
   "Arrange…" button (enabled by gdu.19).
6. Multiple displays: click the item on each display; the panel opens on the display holding the item, clamped to
   that display's visible frame.
7. Inline mode: Reveal mode = "Inline" restores the old toggle that reveals the hidden section in the real bar.
8. Clicking an entry only logs `overflow click <key>` for now (forwarding arrives with gdu.17).

## Live hide detection

Bead sommelier-gdu.38, 2026-11-04, MBDummy only, Bartender 7 quit, entitled writer `scripts/ccset.swift` (built outside the repo). After a cfprefsd-notified hide
MenuBarAgent's hosted AX tree contains no Dummy-A/Dummy-B element at all, while the app's own `AXExtrasMenuBar` still reports on-bar frames
and `stale` stays false. `MenuBarScanner` therefore reports an app item as `isOnMenuBar=false`, `hidden=notHosted` (`mbprobe list` prints `hidden=notHosted|parkedFrame`, `list --json` has a `hidden` key) when
ALL hold: the owner runs, the frame says on-bar, the item has an AX identifier (description-only items must also be unjoined), it was seen hosted by name in an earlier read
(`seenHostedKeys`; never-seen items stay frame-ruled so an app whose hosted element is named differently can never loop as "hidden"), and a COMPLETE hosted read has no element of that name.
Incomplete reads keep the frame rule, except that an item already proven hidden stays hidden until a read shows it hosted again.

**Detection is reported by the FIRST COMPLETE full scan after the write.** The bound is the duration of a full scan (about 1.1-3 s here) plus read completeness, not the detection logic.
A first scan whose hosted read is incomplete (failed AX reads; seen once with 16 failed reads) reports the OLD state (on-bar), so a verifier must poll until a complete
read and must not trust a single scan. Do not assume sub-second detection.

Procedure: `./ccset ie.boboco.mbdummy 0`, then `mbprobe list --json` in a loop every 0.5 s for 5 s (scan-bound).
| Step | Observation |
|---|---|
| write `isAllowed=0` (ccset call itself) | 12-15 ms |
| hide: write -> first complete scan reporting both dummies `notHosted` | implementer runs +0.95 s, +1.14 s; reviewer runs +1.59 s, +3.07 s, +4.13 s (range 0.95-4.13 s). One reviewer first scan (+2.54 s) was incomplete (16 failed reads) and reported on-bar. |
| hide, following scans | stay `notHosted` (sticky rule; before it, one incomplete scan flipped back to on-bar) |
| show (`ccset ... 1`) -> first scan reporting both on-bar | implementer +1.5 s; reviewer +1.11, +1.65, +1.90 s |
| non-dummy on-bar order, before vs during hide vs after show | identical (18 items; only the "64%" -> "65%" readout title changed) |
| fast path (`list --fast`, one-shot process, 0.3 s hosted deadline) | reports `notHosted` only on complete reads, which are intermittent on this machine (first one at +4.05 s in one run). It is not a bounded-latency signal. |

## Live hide/show

Bead sommelier-gdu.39. The actuator writes `isAllowed` through CFPreferences (cfprefsd-notified, needs the app-group entitlement) and polls full scans until a complete read confirms it; respawn is the fallback.
Use the ENTITLED binary: `make build` re-signs `$(swift build --show-bin-path)/mbprobe` with `Resources/Sommelier.entitlements`; `swift run mbprobe` is unentitled.
Bartender quit (`osascript -e 'tell application "Bartender 7" to quit'`), `make dummy ARGS="--count 2"`, back up both plists first.

    MB=$(swift build --show-bin-path)/mbprobe
    codesign -d --entitlements :- $MB          # shows group.com.apple.controlcenter
    $MB permissions                            # "live hide/show: available"
    $MB list --json >/dev/null                 # seed (the scanner only reports live hides for items it saw hosted)
    $MB hide status:MBDummy::Dummy-A           # MECHANISM live ACTUATION_MS ~0.6-5 s; pgrep -x MenuBarAgent unchanged
    $MB show status:MBDummy::Dummy-A
    $MB layout init-from-current --file SCRATCH/layout.json; cp SCRATCH/layout.json SCRATCH/layout-visible.json
    $MB layout move status:MBDummy::Dummy-A hidden --file SCRATCH/layout.json   # same for Dummy-B
    $MB apply --file SCRATCH/layout.json       # "actuator: live: verified after N scan(s) ... no respawn"
    cp SCRATCH/layout-visible.json SCRATCH/layout.json; $MB apply --file SCRATCH/layout.json
    # fallback: cp $MB SCRATCH/mbprobe-unent; codesign --force --sign - SCRATCH/mbprobe-unent
    #   -> permissions says "unavailable"; hide/show print MECHANISM respawn and still verify; no
    #   ~/Library/Preferences/group.com.apple.controlcenter.plist may appear.

Do NOT restore a dummy to "visible" in a scratch layout by `layout move ... visible` without an index: it is appended after Clock and the engine's order phase then
drags real (iStat) items. Restore from a copy taken while the dummies were visible. Results 2026-11-04: hide/show live 0.6-5.1 s, 40 ops (20 cycles), agent pid constant (implementer soak 40/40 live; the reviewer's run was 4/6 live under the old 6 s wall bound because of incomplete-read streaks),
non-dummy on-bar order identical; engine apply hide 0.71 s / show 0.63 s actuation (5.6 / 6.5 s wall); unentitled copy: respawn path, both verified, no stray plist.

Poll bound (after the reviewer's finding): full scans every 0.5 s; the FIRST complete read decides, an unsatisfied complete read gets one more complete read, hard ceiling 8 scans / 20 s. The respawn fallback should now occur only when no complete read arrives within that ceiling (or two complete reads disagree). The trace states scans taken, complete count and the ending rule.

## Layout import mirrors the bar

`init-from-current` must write `visible` in the observed left-to-right order, modules included (sommelier-gdu.43: `LayoutBuilder`
used `Layout.append`, whose "insert before the trailing module run" default reversed the modules and moved them to the end).
Read-only check (never the real layout file):

    MB=$(swift build --show-bin-path)/mbprobe
    $MB layout init-from-current --file SCRATCH/layout.json --force   # retry on "scans did not agree"
    $MB list                                                           # on-bar section, left to right
    $MB plan --file SCRATCH/layout.json                                # phase: converged, actions (0), skipped (0)

Result 2026-11-04 (22 identified items, widths > 1): on-bar and `visible` sequences identical. Mid-bar module and trailing block:
`0 systemuiserver::TimeMachine, 1 module:AudioVideoModule, 2 TextInputMenuAgent, 3 KeepingYouAwake, 4-8 iStat weather/network/disks/battery/sensors,
9 GateOpener, 10-11 iStat memory/cpu, 12 signal, 13 corsair ControlCenter, 14 vpnswitch, 15 mcpmaestro, 16 FloTile, 17 iStat time,
18 Bartender::GoldenGateBar, 19 airmail2hookmark, 20 module:com.apple.menuextra.controlcenter, 21 module:Clock`.
Before the fix the same bar produced `... 19 airmail2hookmark, module:Clock, module:com.apple.menuextra.controlcenter, module:AudioVideoModule,
module:com.apple.menuextra.focusmode, module:WiFi` (all modules appended, in reverse). `plan` on the fresh file: converged, 0 actions, 0 skipped.

## System overflow
Read-only, 2026-11-04. Normal bar: 5 x `mbprobe list --json` -> 0 `"systemOverflow" : true`. Full bar (MBDummy `--count 31`):
14 items flagged, all left of the chevron. The bar churns with dummies (a dummy can flip parked/on-bar, so a `show`, `newItems` or
"scans did not agree" can appear); plans were retried until an order/converged phase. Unedited `init-from-current`, then `plan`:
```
phase: converged  (observed 53 on bar, 28 parked; showHidden=false)  systemOverflow=14
actions (0):
skipped (0):
```
Scratch file with two adjacent drawn dummies (N, M) swapped:
```
phase: order  (observed 53 on bar, 28 parked; showHidden=false)  systemOverflow=14
actions (1):  1. move status:MBDummy::Dummy-N after status:MBDummy::Dummy-M      skipped (0)
```
No action names the chevron or an overflowed item. `apply` not run; the real layout.json was not touched.

## Arrange window

Dev safety: always run with `SOMMELIER_LAYOUT_FILE=<scratch>/layout.json` (README "Developing"). Quit Bartender first
(`osascript -e 'tell application "Bartender 7" to quit'`), `make dummy`, `make app`, then
`SOMMELIER_LAYOUT_FILE=... SOMMELIER_OPEN_ARRANGE=1 make app-run` (log: `build/sommelier.log`; the line `arrange rows:` is what the
window shows, `arrange:` lines give drop -> verified timings). Act on MBDummy items only. Relaunch Bartender at the end.

Manual checklist (every step: the capsule shows "⟳" until `mbprobe list` agrees, then "✓"):
1. Visible -> Hidden: drag Dummy A into the Hidden strip (or right-click > Move to Hidden). Dummy A AND Dummy B (same app = one hide
   unit) show "⟳", leave the bar (agent pid unchanged), appear in Hidden with "✓".
2. Hidden -> Visible at index 0: drag Dummy A to the left edge of the Visible strip (log: `drop ... visible slot 0`). Both return to the
   bar; `mbprobe list` shows them at the dropped position; "✓" only after that.
3. Reorder within Visible: drag Dummy A two capsules right (real Cmd+drag, 5-15 s). Ghosts at the target while it runs; on a failure the
   capsule shows "⚠" with the error as tooltip and Retry in the menu.
4. Always hidden: drag Dummy A into Always hidden; use "Reveal in menu bar" / left click on the Sommelier item: it stays hidden.
5. System items: Clock/Control Center/Focus are greyed anchors with a "⊘" (tooltip: modules cannot be moved or hidden); there is no
   drag. They never show "⚠" because nothing is attempted on them.
6. Toolbar: "Hide what does not fit" is disabled unless macOS has an overflow chevron on the bar (`mbprobe list` shows "overflow");
   with a full bar (`make dummy ARGS="--count 31"`) it is enabled and its sheet lists the units that will hide. "Adopt current order"
   shows its confirmation. The Bartender banner appears while Bartender runs (the app is paused).

Headless drop pipeline (no mouse): `SOMMELIER_ARRANGE_MOVE="status:MBDummy::Dummy-A|hidden|-"` (key as printed by `mbprobe list`; the
index is a position in the target section's layout, "-" = append / before the trailing system block). Chain with `;`, spacing
`SOMMELIER_ARRANGE_MOVE_INTERVAL`.

Results 2026-11-04 (live, Bartender quit, scratch layout, Dummy A/B only): hide `...|hidden|-`: drop -> "⟳" 0.13 s, verified
membership 6.7 s actuation, "✓" 11.6 s after the drop, agent pid constant; `...|visible|1`: back at bar index 1/2 per
`mbprobe list`, "✓" 13.2 s (the order phase did a real drag); `...|visible|3` (past SystemUIServer and Focus): two real drags, "✓" 16.8 s;
right-click > Move to Hidden driven by CGEvent clicks: "⟳" at 2 s, "✓" 5.6 s; a real mouse drag from Hidden to Visible (CGEvent): `drop ... visible
slot 2`, "✓" 2.5 s; 10 chained moves 1.5 s apart: no `MAIN ACTOR STALL`, window redrew throughout, final state converged and verified.
A failed move was not provoked live (the badge mapping `.failed` -> "⚠"+error is unit-tested). End state: non-dummy order identical to
the start (`init-from-current` before/after), real `layout.json` absent, `trackedApplications` blob equal to the backup.
