# Manual testing

## QA run (ordered)
Run the sections below in this order for a full pass; each links to its checklist.
1. First launch: [Developer launch trick](#developer-launch-trick)
2. Permissions: onboarding and Accessibility grant (README "Permissions"; `mbprobe permissions`)
3. Panel: [Overflow panel](#overflow-panel), [Live hide detection](#live-hide-detection), [Live hide/show](#live-hideshow)
4. Arrange: [Layout import mirrors the bar](#layout-import-mirrors-the-bar), [System overflow](#system-overflow), [Arrange window](#arrange-window)
5. Click-forwarding: [Click-forwarding](#click-forwarding)
6. Robustness: [Robustness (gdu.21)](#robustness-gdu21)
7. Release smoke: [Release smoke (reviewer/human)](#release-smoke-reviewerhuman)

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
   Synthetic clicks (gdu.62): `cliclick c:x,y` posts mouse-down and mouse-up with zero gap, and the status item (hosted by
   MenuBarAgent) drops about 25-35% of them: the app then logs nothing, because neither the down nor the up reaches the
   app (a temporary NSEvent monitor showed global down/up events but no local event and no `clicked()`); when a click does
   arrive the local down comes ~50 ms after the global one and `clicked()` runs once, so the app-side action is not at fault.
   Measured 2026-11-05 (Bartender quit, item centre 1000,14 from the logged item frame, toggles counted from `before show` /
   `overflow hide` lines): cliclick 15/20 (2 s spacing), 13/20 (0.8 s); down-up gap 10 ms 16/20, 25 ms 17/20, 40 ms 20/20,
   70 ms 39/40; after the final build 20/20 at 70 ms (10 open/close pairs, log toggles). A human click is held 60-150 ms, so real clicks are not affected; no app change. In tests click with a
   gap of at least 70 ms (CGEvent down, sleep 0.07, up) or accept cliclick misses and re-click after checking the log.
   gdu.37: any mouse-down outside the panel closes it, including another app's menu bar item (only the Sommelier item
   itself is exempt and toggles). The panel takes keyboard focus while open (key window, `makeKeyAndOrderFront`), a
   local plus a global keyDown monitor close it on Escape only while it is visible; `cliclick kp:esc` is not delivered
   (use `osascript -e 'tell application "System Events" to key code 53'`). `place()` runs once on show and again only
   when the entries, feedback errors, show-names setting, anchor or screen frame change (log `place() run #N`).
   Live 2026-11-05 (Bartender quit, pointer on the panel): Escape closed it 5/5 (`overflow hide: escape`); with Finder
   activated after opening, 3/3 (1 global, 2 local); clicking Control Center (1285,12) closed it 3/3 (`click outside at {1285, 866}`),
   Escape then closed that menu; own item click toggles (`overflow hide: requested`); `place() run #1` only, no further
   runs over 5 s open. Note: moving the pointer off panel+bar closes it after 400 ms, so test Escape with the pointer on the panel.
3. Show names off: Settings > "Show names in panel" shows icons only; hover shows the name as tooltip.
4. Many items: when the row is wider than 80 % of the screen it scrolls horizontally.
5. Empty state: with nothing hidden (or no hidden app running) the panel reads "Nothing hidden" with a disabled
   "Arrange…" button (enabled by gdu.19).
6. Multiple displays: click the item on each display; the panel opens on the display holding the item, clamped to
   that display's visible frame.
7. Inline mode: Reveal mode = "Inline" restores the old toggle that reveals the hidden section in the real bar.
8. Clicking an entry only logs `overflow click <key>` for now (forwarding arrives with gdu.17).

## Settings window (gdu.59)

Open with `SOMMELIER_OPEN_SETTINGS=1 make app-run` (Bartender quit first). Title bar reads "Sommelier Settings"; the window resizes per tab (540 pt wide). On every tab check: nothing clipped at
any edge, labels left and controls right in aligned columns, captions in secondary style, no empty band at the bottom, no wrapped single words.
- General: grouped rows (Start at login, New items, Reveal mode, Show names, Auto re-hide); a second group with "Allow menu bar restart as a last resort" plus its footnote.
- Permissions: one group per permission (status dot at the trailing edge, caption, Request/Open buttons trailing), signature footnote below.
- Spacing: each row has label, slider (no tick marks), numeric field, "pt", stepper, caption underneath. The caption shows the range ("0–24 pt"), "pt" stays visible, the field has a bezel and the stepper steps 1 pt within 0–24. Unset shows "Default" in the field and "System default" in the caption. Type 4 then Return (or
  click elsewhere): `defaults -currentHost read -globalDomain NSStatusItemSpacing` prints 4. "Reset to system default" (bottom trailing) is disabled while both keys are unset and removes both keys.
  Footnote spans the full width. Leave both keys absent afterwards.
- Standalone onboarding window (`SOMMELIER_SHOW_ONBOARDING=1`): heading "Sommelier needs permission", 540 x 396 pt, both groups and the footnote visible without scrolling.

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
| hide: write -> first complete scan reporting both dummies `notHosted` | implementer runs +0.95 s, +1.14 s; reviewer runs +1.59 s, +3.07 s, +4.13 s (range 0.95-4.13 s; docs/findings-live-trigger.md rounds this to 1.0-4.1 s). One reviewer first scan (+2.54 s) was incomplete (16 failed reads) and reported on-bar. |
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
drags real (iStat) items. Restore from a copy taken while the dummies were visible. Results 2026-11-04: hide/show live 0.6-5.1 s (not a ceiling: 7.2 s was seen later), 40 ops (20 cycles), agent pid constant (implementer soak 40/40 live; the reviewer's run was 4/6 live under the old 6 s wall bound because of incomplete-read streaks),
non-dummy on-bar order identical; engine apply hide 0.71 s / show 0.63 s actuation (5.6 / 6.5 s wall); unentitled copy: respawn path, both verified, no stray plist.

Poll bound (after the reviewer's finding): full scans every 0.5 s; the FIRST complete read decides, an unsatisfied complete read gets one more complete read, hard ceiling 8 scans / 20 s. The respawn fallback should now occur only when no complete read arrives within that ceiling (or a second complete read is still unsatisfied). The trace states scans taken, complete count and the ending rule.

## Layout import mirrors the bar

`init-from-current` must write `visible` in the observed left-to-right order, modules included (sommelier-gdu.43: `LayoutBuilder`
used `Layout.append`, whose "insert before the trailing module run" default reversed the modules and moved them to the end).
Read-only check (never the real layout file):

    MB=$(swift build --show-bin-path)/mbprobe
    $MB layout init-from-current --file SCRATCH/layout.json --force   # retry on "scans did not agree"
    # on "scans did not agree" it names the keys stale in the last scan and the keys that differed between the last two scans (gdu.30)
    # stale items in an AGREED scan: self-positioning owners (iStat) are written with a stderr "note: N self-positioning items were stale"; any other stale item (a parked one can be) refuses with the keys named (gdu.30)
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

### Overflowed bar, idle (gdu.69)
Live 2026-11-05 (Bartender quit, the user's naturally full bar, `mbprobe layout init-from-current` scratch layout via `SOMMELIER_LAYOUT_FILE`, `SOMMELIER_OPEN_ARRANGE=1`, Sommelier run directly, 5 min 22 s idle, no dummies). `mbprobe overflow` (new, read-only: chevron frame, expanded, hosted frames) shows the chevron; root cause found with it: the scan had NO chevron item because the hosted-to-app frame join paired the chevron element with Script Menu, so nothing was flagged. After the fix `mbprobe list` flags exactly the items left of or on the chevron plus the stacked pile within its reach (chevron x 786: iStat Network/Weather, SystemUIServer, KeepingYouAwake, TextInputMenuAgent, 1Password at 781, BoltAI, TextSniper, Tailscale, RescueTime, DEVONsphere, Grammarly = 12; first drawn item iStat Disks at 813 not flagged; before the fix 0). Log: 0 `failed N passes` / `marked failed` lines, 0 drag lines, every pass `plan: phase=converged actions=0`. Arrange window (`screencapture -l <window id>`): the 12 show the neutral orange `«` badge, no red anywhere, status line "Converged". End state: Sommelier stopped, Bartender 7 relaunched (pid 3338), `group.com.apple.controlcenter.plist` and `com.apple.controlcenter.plist` byte-equal to the backups, `com.apple.MenuBarAgent.plist` differs only in `MenuBarAnalytics.lastReportedTrailingItemCount` (22 -> 24, macOS's own counter), real `layout.json`/`slot-hints.json` sha unchanged. `swift test`: 614 tests.

## Arrange window

Dev safety: always run with `SOMMELIER_LAYOUT_FILE=<scratch>/layout.json` (README "Developing"). Quit Bartender first
(`osascript -e 'tell application "Bartender 7" to quit'`), `make dummy`, `make app`, then
`SOMMELIER_LAYOUT_FILE=... SOMMELIER_OPEN_ARRANGE=1 make app-run` (log: `build/sommelier.log`; the line `arrange rows:` is what the
window shows, `arrange:` lines give drop -> verified timings). Act on MBDummy items only. Relaunch Bartender at the end.

Manual checklist (every step: the capsule shows "⟳" until `mbprobe list` agrees, then "✓"):
1. Visible -> Hidden: drag Dummy A into the Hidden strip (or right-click > Move to Hidden). Dummy A AND Dummy B (same app = one hide
   unit; in general one Control Center entry, so a helper hides with its parent app, gdu.75 `HideUnitEntryTests`) show "⟳", leave the bar (agent pid unchanged), appear in Hidden with "✓".
2. Hidden -> Visible at the first movable slot (index 0 among movable items; with Wi-Fi leftmost that is right after it): drag Dummy A to
   the left edge of the Visible strip. Both return to the bar; `mbprobe list` shows them at that position; "✓" only after that.
3. Reorder within Visible: drag Dummy A two capsules right (real Cmd+drag, 5-15 s). Ghosts at the target while it runs; on a failure the
   capsule shows "⚠" with the error as tooltip and Retry in the menu.
4. Always hidden: drag Dummy A into Always hidden; use "Reveal in menu bar" / left click on the Sommelier item: it stays hidden.
5. System items: Clock/Control Center/Focus are greyed anchors with a "⊘" (tooltip: modules cannot be moved or hidden); there is no
   drag. They never show "⚠" because nothing is attempted on them.
6. Toolbar: "Hide what does not fit" is disabled unless macOS has an overflow chevron on the bar (`mbprobe list` shows "overflow");
   with a full bar (`make dummy ARGS="--count 31"`) it is enabled and its sheet lists the units that will hide. "Adopt current order"
   shows its confirmation. The Bartender banner appears while Bartender runs (the app is paused).
7. iStat items are never dragged (mbprobe list order of iStat unchanged by a reorder pass); hiding them still works; their Arrange row says
   "Positions itself" (gdu.33); an order-only drop of an iStat row inside Visible is refused with that reason, hide/show is accepted (gdu.61). A drop or Move left/right of another row that would put it on the far side of an iStat row is refused with "cannot cross <name>: it positions itself; move it in iStat Menus instead" (gdu.67).

Headless drop pipeline (no mouse): `SOMMELIER_ARRANGE_MOVE="status:MBDummy::Dummy-A|hidden|-"` (key as printed by `mbprobe list`; the
index is 0-based among MOVABLE items of the target section (modules do not count; `mbprobe layout move` is 1-based), passes through
`ArrangeDrop.index` exactly like a UI drop, so `0` = first movable slot (after leading anchors) and `99` = before the trailing system
block; "-" = append). Chain with `;`, spacing `SOMMELIER_ARRANGE_MOVE_INTERVAL`.
`SOMMELIER_OPEN_ARRANGE=1` is no longer needed (gdu.48); keep it only to watch the `arrange rows:` lines.

Arrange tracker (gdu.48) reviewer steps (live, Bartender quit, scratch layout, Dummy A/B only, NO `SOMMELIER_OPEN_ARRANGE`):
1. `make dummy`, `make app`; `SOMMELIER_LAYOUT_FILE=<scratch>/layout.json SOMMELIER_ARRANGE_MOVE="status:MBDummy::Dummy-A|hidden|-" make app-run`.
   Expect in `build/sommelier.log`: `arrange env move: ...`, no `no Control Center entry` rejection, `arrange: submit layout; moved=...`.
2. Expect `arrange: ... verified in place N s after the drop (observed order matches)` for Dummy A and B on the FIRST pass after the
   `setLayout` log line (no second pass needed, no 90 s `NOT applied`); `mbprobe list` agrees.
3. Chain drops with `SOMMELIER_ARRANGE_MOVE_INTERVAL=0.2` (`...|hidden|-;...|visible|1`): no capsule stays "⟳" and the second drop does not
   undo a new item the engine appended (`New item:` notice; `layout.json` still lists it).
4. After a failure (`stoppedAfterFailures` or a "N failed" line), fix the bar by hand, wait for a pass: the log shows `cleared failure for
   ... : now in place` and the status line stops counting it.
Unit coverage: `Tests/SommelierCoreTests/ArrangeRevisionTests.swift`.

Results 2026-11-04 (live, Bartender quit, scratch layout, Dummy A/B only): hide `...|hidden|-`: drop -> "⟳" 0.13 s, verified
membership 6.7 s actuation, "✓" 11.6 s after the drop, agent pid constant; `...|visible|1`: back at bar index 1/2 per
`mbprobe list`, "✓" 13.2 s (the order phase did a real drag); `...|visible|3` (past SystemUIServer and Focus): two real drags, "✓" 16.8 s;
right-click > Move to Hidden driven by CGEvent clicks: "⟳" at 2 s, "✓" 5.6 s; a real mouse drag from Hidden to Visible (CGEvent): `drop ... visible
slot 2`, "✓" 2.5 s; 10 chained moves 1.5 s apart: no `MAIN ACTOR STALL`, window redrew throughout, final state converged and verified.
A failed move was not provoked live (the badge mapping `.failed` -> "⚠"+error is unit-tested). End state: non-dummy order identical to
the start (`init-from-current` before/after), real `layout.json` absent, `trackedApplications` blob equal to the backup.

Corrective pass results (2026-11-04, same setup): (a) first seconds after launch: Visible shows "No observation yet - scanning..." with no
capsules (log `arrange rows: V[]`, screenshot burst2.png), Hidden renders from the layout; (b) after observation Visible == `mbprobe list`
(Sommelier's own item excluded); (c) `...Dummy-A|visible|0` -> bar index 1,2 right after Wi-Fi, "✓" 18.0 s after the drop, only after
`mbprobe list` agreed; (d) `...|visible|99` -> bar index 22,23 directly before Control Center/Clock, "✓" at 20.8 s, no "⊘"; (e) two moves 1 s
apart (`hidden`, then `visible|0`): capsules stayed "⟳" until a pass that started after the second drop reported; that pass FAILED
("not verified: expected membership change, saw unchanged") and both capsules showed "⚠" with that text (an engine-level result of
overlapping layouts, shown honestly). Stall detector now logs timer lateness > 100 ms; none seen.

### Rapid hide-then-show (gdu.47) reviewer steps

Live steps (menu bar interaction; reviewer only, MBDummy items only). Unit tests: `SupersedeTests`, `oppositeBatchRightAfterAWriteWaitsAndRescans`.
1. `make dummy`, `make app`; use a scratch layout: `SOMMELIER_LAYOUT_FILE=<scratch>/layout.json`.
2. `SOMMELIER_ARRANGE_MOVE="<Dummy-A key>|hidden|-;<Dummy-A key>|visible|0" SOMMELIER_ARRANGE_MOVE_INTERVAL=1 SOMMELIER_LAYOUT_FILE=<scratch>/layout.json make app-run` (key as printed by `mbprobe list`, e.g. `status:MBDummy::Dummy-A`).
3. Expected log: either `setLayout coalesced with an earlier one inside` (interval shorter than 300 ms; not at 1 s) or, at 1 s, `pass superseded by setLayout` (the hide pass was observing or its batch in flight, then `batch finished (...) after the layout changed; not judged against the new layout`); the final pass shows Dummy-A again. Both capsules end "✓"; Dummy-A is on the bar at index 0 per `mbprobe list`; the log has NO `not verified` and NO `expected membership change`; at most one `live: verified` for the hide and one for the show.
4. Repeat with `SOMMELIER_ARRANGE_MOVE_INTERVAL=5`: the hide pass completes and verifies on its own, then the show pass; no `superseded` expected; both capsules "✓", no "⚠".
5. Regression: a hide that genuinely cannot work (e.g. a system module) still shows its failure; nothing in this change hides real failures.

## Launch latency (gdu.46)

Bartender quit, no dummies, `SOMMELIER_LAYOUT_FILE=<scratch>/layout.json`, 22 s per launch, `pkill -x Sommelier` between launches; times from
`build/sommelier.log`-style output (`launch trusted=true` = 0). "first" = `first observation published (provisional, unsettled)`
(or the first settled `plan:` line if earlier); "settled" = first `engine: plan:` line (two agreeing scans). Launches 1 and 6 start
without a layout file (first-launch layout creation path).

| launch | first observation (s) | first settled (s) | "scans did not agree" |
|---|---|---|---|
| 1 (no layout file) | 2.5 | 4.6 | no |
| 2 | 2.5 | 5.1 | no |
| 3 | 0.8 | 5.4 | no |
| 4 | 0.8 | 6.1 | no |
| 5 | 1.6 | 6.7 | no |
| 6 (no layout file) | 0.7 | 6.4 | no |
| 7 | 1.7 | 5.9 | no |
| 8 | 0.8 | 1.4 | no |
| 9 | 0.9 | 1.3 | no |
| 10 | 2.6 | 7.1 | no |

An observation is published within ~3 s in every launch (worst 2.6 s); settling usually completes within 10 s (worst 7.1 s here) but can exceed it under iStat AX timeouts: the reviewer's separate 5 launches settled in 1.4-10.6 s (one at 10.55 s after three incomplete iStat scans). Before the change (same machine, same day, first 10-launch run of the pre-fix
provisional rule): launches 3 and 4 published nothing for 15+ s (first pass: 5-6 consecutive incomplete scans), and a first-launch (no layout file) start published
only after 12.5 s because the strict layout-creation read blocked the engine. setLayout -> pass start: 0 ms idle (4 of 4 idle samples), 464-499 ms when it
abandoned an observation, 1.4 s until the running pass re-planned during a drag (the drag in flight finishes first).

Reading the log: `engine: observer: observe scan N: hostedComplete=... onBarStale=... agree=...` per scan (a scan with iStat's read timing out
takes ~2.6 s and has `hostedComplete=false onBarStale=8`); `engine: pass started N ms after setLayout|trigger`; `engine: pass delayed: ...`;
`engine: observation unsettled; not actuating`; `engine: setLayout: abandoning the observation in progress`. setLayout latency check with
MBDummy only: `SOMMELIER_ARRANGE_MOVE="status:MBDummy::Dummy-A|visible|0;status:MBDummy::Dummy-A|visible|6" SOMMELIER_ARRANGE_MOVE_INTERVAL=22`
(a hide of MBDummy is rejected without a Control Center entry; use visible-to-visible moves), then grep `after setLayout|picked up|abandoning`.

## Click-forwarding
Live protocol (gdu.17, 2026-11-04, macOS 27.0.1; Bartender quit for the run and relaunched after; items the user keeps hidden through
Control Center, `isAllowed=false`). `mbprobe activate <key> --escape-after 3` (CGEvent Escape closes the menu; the activator's own
close detection noticed it: `closed_by=escape`). Times in ms: reveal = activation entry (which includes the full locating scan, 0.6-1.8 s)
to the item being drawn; click->menu = click posted to a menu/popover child being present through Accessibility.

| Item (key) | Mechanism | Reveal (entry -> drawn), 3 runs | Click -> menu | Menu location | Re-hide |
|---|---|---|---|---|---|
| Tot `status:com.iconfactory.Tot::Item-0` (popover) | revealClick | 736 / 1576 / 1766 (earlier runs 857, 698, 2652) | 88-130 (3 of 6 runs: not observed through AX; the popover was open per screenshot) | under the item, x 827-1353, y 26+ | yes, agent pid unchanged |
| Yoink `status:at.EternalStorms.Yoink::Item-0` (menu) | revealClick | 764 / 797 / 682 / 1920 / 2521 | 36-52 | under the item (1071,31, 265x259) | yes |
| Moom `status:com.manytricks.Moom::com.manytricks.Moom.StatusItem` (menu) | revealClick | 1563 / 783 / 2534 / 1060 | 22-56 | under the item (1077,31, 327x224) | yes |

Click->menu is 22-130 ms, far inside the 700 ms target. The reveal part is dominated by the `LivePlatform.scan()` that locates the item
(0.6-1.8 s, a follow-up bead covers caching it) plus a hosted-tree read that is sometimes incomplete; the live show itself lands in ~60-300 ms.
**Reveal latency before/after (sommelier-d5c, 2026-11-05, Bartender 7 quit, MBDummy Dummy-A live-hidden, headless via `SOMMELIER_ACTIVATE` through the app's `ItemActivator`; MBDummy items have no menu, so click -> menu was NOT re-measured: the earlier 22-130 ms stands).**
Phases are in the activator log as `phase locate|baseline|show-write|drawn|click|menu-open` with `t=<ms>` since entry. Entry -> drawn, 5 runs each:

| | locate | baseline hosted read | show-write | drawn after write | entry -> drawn |
|---|---|---|---|---|---|
| before (full scan) | 954 / 594 / 1799 / 592 / 1468 | 28 ms x5 (earlier runs: 0.9-7.3 s) | 1-2 | 71 / 1975 / 71 / 68 / 68 | 1063 / 2607 / 1914 / 698 / 1572 |
| after (cached element, group-count proof, 300 ms baseline budget) | 27 / 28 / 12 / 31 / 20 | skipped at 300 ms x4, 237 ms x1 | 2-4 | 57 / 57 / 57 / 55 / 57 | 420 / 397 / 378 / 396 / 319 |

Entry -> click posted is now 0.42-0.53 s. The remaining time is the 300 ms baseline budget: under load the full hosted read takes 0.5-3 s,
and a reveal no longer waits for it (no re-hide evidence for that run; the engine hides the unit on its next pass as usual).
Re-run: `SOMMELIER_ACTIVATE_DELAY=<s>` delays the headless activation (default 3 s) to measure in steady state.
The AXPress fallback (`--ax-press` or reveal timeout) opened Yoink's menu at the screen-left strip (-5, 34), as recorded in
docs/findings-visibility.md; its AX press returned 0 here.
Right click (`--right`): Moom opens its menu under the item (same as left); Yoink received the right click and showed no menu under the
item (its shelf window opened off to the right, AX reported a window at x 1775); Tot not tried. Edge: Moom quit before activating ->
`failed: the app is not running` (Moom relaunched with `open -b` afterwards).
Through the app (`SOMMELIER_LAYOUT_FILE=<scratch>/layout.json SOMMELIER_ACTIVATE="status:com.iconfactory.Tot::Item-0"`, Sommelier binary run
directly): log shows `engine: hold: com.iconfactory.Tot revealed from the overflow panel`, `menu observed 92 ms after the click`, then TWO
engine passes during the 31 s the popover stayed open that planned `phase=converged actions=0` (Tot visible, layout hidden, not hidden), then
after Escape `menu closed (escape)`, `unit hidden again`, `hold ... released; reconciling` and a plan `hide Tot` that fell back to one agent
respawn (see the known limitation in docs/architecture.md; the respawn changed the MenuBarAgent pid, which does not happen with the activator
alone).
Caveats of the live runs: `mbprobe list` reports the three (identifier-less) items as ON the bar after a reveal+re-hide although they are not
drawn (stale app-side frame); `mbprobe agent-restart` re-parks them. Screenshots of Tot's popover can contain private text: do not archive them.

### Click-forwarding: user-felt latency (corrective pass)
The metric that matters is **panel click -> menu visible** (mouse-up on the entry to the menu/popover being present), not click->menu
(the synthesized click to the menu, 22-130 ms, secondary). The 700 ms target applies to the panel metric and is met only for the fastest
reveals: reviewer panel runs Yoink 806 ms, Tot about 1658 ms; the Moom run missed it (accepted a frame still sliding in, see below); my
`SOMMELIER_OPEN_PANEL=1` + `cliclick` run on the Tot entry: mouse-up 14:36:33.807 -> `menu observed` 14:36:34.359 = 552 ms (locate scan
only 170 ms that time). The `mbprobe activate` reveal (entry -> drawn) after the fixes below was 0.8-2.8 s (Moom x8), because the scan and the
now-retrying hosted read dominate; so typical panel click -> menu is 1-3 s with an observed upper bound of 3.4 s (reviewer: locate 1.58 s + baseline reads 1.46 s), the target is NOT generally met (latency work: bead sommelier-d5c).
Reviewer's Keyboard Maestro case: a mis-aimed reveal fell back to AXPress and the menu appeared at an unrelated place (the fallback caveat).
Fixes this pass: landing needs a SETTLED frame (y 0...5, identical +-1 pt on two polls 50 ms apart) plus the agent hosting one more item;
the hosted baseline is read after the hold, right before the write; an incomplete hosted read never lets a stale frame be believed (retry, then
AXPress `axPressParked` for left, unavailable for right); a click or press that opens no menu within 1.5 s returns `.failed(.noMenu)` (re-hide and
hold release still happen). Moom x4 with `--escape-after 5`: 4 of 4 opened under the item; an earlier x6 batch with the old rules produced 2 `no
menu` failures that were AXPress fallbacks on a stale frame (the hosted fast read was incomplete), which is why the baseline read now uses the
retrying tree read. The panel's inline red caption is drawn under the outlined entry (tooltips do not show on a non-activating panel); live check:
a not-running Tot refreshed the entries (entry gone, log `failed: the app is not running`), so the caption itself was only seen by the reviewer's
outline run. `mbprobe activate` refuses while a Sommelier process runs (no engine hold) unless `--force`.

### Reveal into the system overflow (gdu.65)
- [x] Live 2026-11-05 (Bartender quit, MBDummy `--count 2` on the user's naturally full bar, chevron at x 786, scratch layout, real panel click at 70 ms hold, Sommelier run directly): Dummy-A revealed 3 times from the panel landed stacked at x 772 behind the chevron; detection `phase overflow: landed frame ... stacked` at +6/+3/+3 ms after drawn; path (a) each time: chevron click +126/+108/+108 ms after detection, expanded strip shows the item at x 307 after 106/106/107 ms, item clicked at 323,15 (no chevron side effect), strip collapsed by one chevron click after the menu wait (the dummy has no menu: "no menu opened" is honest; the strip-open-to-click part is what was exercised); entry -> click posted 790/579/451 ms; re-hide 2.5-4.9 s. Escape does not collapse the strip; a chevron click does. Chevron collapsed afterwards (AX: "Show Hidden Menu Bar Items", AXMenuBar x 787), non-dummy on-bar order and parked set identical before/after (`mbprobe list --json`), both plists equal to the backups, real layout.json untouched. Not exercised live: path (b), a real item with a menu (unit tests only). `swift test`: 609 tests.

### Click-forwarding polish (gdu.49) reviewer steps
Unit tests: `OverflowFeedbackModelTests` (one clear task per key; a not-running entry stays rendered until its error clears), `ItemActivatorTests` (hard cap posts Escape then re-hides with `menuStillOpenAtCap`; Escape that closes the menu leaves no note; cancellation during the baseline read -> `.cancelled`, hold released, nothing written). Live (reviewer; menu-bar interaction is deferred to here):
1. Make two different entries fail back to back (e.g. quit two apps that have panel entries, or click two not-running ones within 4 s): two red captions appear and each clears about 4 s after ITS OWN failure (the first must not stay on screen).
2. Click the entry of an app quit after the panel opened: the entry stays outlined with its caption (`the app is not running`) for the full 4 s, then disappears with the refresh.
3. Open a menu from a panel entry (Moom) and leave it open past 60 s: the log shows `hard cap reached; posting Escape before re-hide`, the menu closes, then `unit hidden again`. (`menu still open after Escape` should not appear unless the app ignores Escape.)
4. If drivable: `SOMMELIER_ACTIVATE=<parked key>` and quit/cancel while the baseline is read -> `.cancelled`, no `unit shown` line, hold released.
5. `swift test`: 476 tests.

### Identifier-less live hide: hosted-element evidence (of7)
Unit tests: `LiveActuatorTests` (exact elements vanished -> live + assumed recorded + show clears; a coincidental vanish with a matching count -> ambiguous, no record, one respawn; another item leaving the bar rejects the evidence; incomplete baseline -> retried scan / scanner cache; poll-scan evidence when the timed probes fail), `MenuBarScannerFastPathTests` (assumed hidden on full and fast scans, never without evidence, readback clears, quit/2 h expiry/readback/pid-reuse, persistence, attributed hosted layout, `HostedEvidence`), `ItemActivatorTests` (re-hide records when the tree is restored, not on a same-count different tree), `LayoutEngineTests` (a hold plans nothing and records no new item). `make test` 381 tests.

Live 2026-11-04 (Bartender 7 quit, `mbprobe` ad-hoc signed, Moom + Yoink, MenuBarAgent never restarted by us; `/private/tmp/.../scratchpad/of7/live3.txt`): show+hide x5 each = 20/20 ops live (hide trace `baseline = pre-write full scan|retried full scan`, then `exactly the unit's 1 element(s) vanished (23 -> 22)` at 800-2500 ms or from a poll scan), pid constant (58992), 0 "no baseline". Write to verified: Moom hides 5729/4274/5655/3360/1830 ms, shows 731/3258/5539/2972/3007 ms; Yoink hides 3785/4987/5437/5154/4608 ms, shows 933/3511/4902/3271/910 ms. `list --json` after every hide: `assumedNotHosted`. 5 consecutive scans flag only Moom and Yoink (23 on-bar items). App run (`SOMMELIER_ACTIVATE=<Yoink key>`, Escape ~6.5 s after launch): engine plans `converged actions=0` during the hold and after, `re-hide verified by hosted-element evidence (tree restored, 23 elements); recorded as assumed-hidden`, pid unchanged, no move/drag/hide planned. An earlier pass of the same loop (count-based width rule, jittering iStat widths) respawned 5 of 20 times; that is why named widths are not compared. End state: Moom/Yoink/Tot parked, `isAllowed` blob equal to the backup, third-party order identical, Bartender relaunched.

Corrective pass 2 (of7): contradiction rule (a) removed (our own status item sat on Tot's stale frame, same width, and cleared the record, then the engine planned a hide that changed nothing and respawned); the record now follows the Control Center `isAllowed` readback (10 s rate limit), plus an `alreadyApplied` actuator short-circuit and an AX identifier on our own status item that excludes it from frame joins. Live 2026-11-04 (Bartender quit, MenuBarAgent pid 73223 constant): app start with Tot live-hidden and listed hidden: 90 s, 0 respawns, every plan `converged actions=0`; 3 more starts x 35 s: 0 respawns, 0 actions; Tot show live 1473 ms, hide live 9193 ms (element evidence), 5 scans flag only Tot; with the record deleted from the cache and the store saying hidden, `mbprobe hide` -> `MECHANISM alreadyApplied`, no write, record restored. `make test` 380.


## Robustness (gdu.21)
Unit tests: `RobustnessTests` (agent watcher: pid change reported once, absence is not a change; empty / unsettled observation never acts; no action
inside the post-respawn window and ONE delayed reconcile afterwards; transient holds dropped on respawn; nothing runs while asleep and wake reconciles;
bursts with one reason are one pass; new-item notice wording; scanner `invalidateAgentState` keeps assumed-hidden), `LayoutEngineTests` (a key failing 3
passes in a row is `.failed` until Retry and never stops the engine; a recovering key breaks the streak; 3 passes of all-failed actions stop the engine).
`make test`: 401 tests (adds `RespawnAccountingTests`: respawn batch strikes out at once, foreign respawn mid-pass discards the observation, own respawn re-bases, watcher absorbs own respawns and keeps its pid across a pause).

### Soak: `scripts/soak-events.sh [--relaunches N] [--toggles M] [--allow-respawn]`
Bartender quit (relaunched at exit if it was running), MBDummy with an ALLOWED Control Center entry (`mbprobe cc-allowed list`; the script never respawns
the agent to create it). Runs the APP's engine on a scratch layout (`SOMMELIER_LAYOUT_FILE`; the real `layout.json` is never touched; the user's real
hidden items are put in "always hidden" so a reveal only ever shows the dummies). Phase V: dummies visible, N/2 quit/relaunch cycles, converged = the
on-bar order equals the baseline (dummies included). Phase H: app restarted with the dummies hidden, N/2 cycles, converged = no dummy on the bar and the
others in baseline order. Phase R: M reveal toggles through `SOMMELIER_DEBUG_REVEAL_FILE` (the file's content `show`/`hide` calls the same
`setShowHiddenSection` as a left click in inline mode; Sommelier's own item can sit in Apple's overflow where it cannot be clicked, so the click is
replaced). Final: non-dummy order equals the baseline, dummies hidden as in the layout, MenuBarAgent pid unchanged (fails otherwise unless
`--allow-respawn`). One layout limitation: both dummies are one hide unit (one app), so "Dummy-A visible, Dummy-B hidden" cannot exist; the phases cover
visible and hidden for the unit instead.

Results (2026-11-04, Bartender quit, MenuBarAgent pid 34707, ~6 min):
| phase | attempts | ok | fail | max s to converge |
|---|---|---|---|---|
| V (dummies visible, relaunch) | 5 | 5 | 0 | 3 |
| H (dummies hidden, relaunch; incl. the first hide) | 6 | 6 | 0 | 6 |
| R (10 x show, 10 x hide again) | 20 | 20 | 0 | 23 |
| final order check | 1 | 1 | 0 | 1 |

MenuBarAgent pid 34707 before and after (no respawn), 0 engine failures logged, `SOAK PASS (0 failures)`, 5 min 21 s. A first full run FAILED in phase R
(hide 6-10): toggling faster than a 5-7 s live batch changed the desired state while a hide batch was in flight, and the post-batch re-plan ("show")
was misread as "the hide did not take", so both dummies were struck three passes in a row and stuck on the bar. Fixed in `LayoutEngine`: a key whose
re-plan wants the OPPOSITE change is not a failure (`DesireChangeDuringBatchTests`); the flapping guard itself worked as designed (logged once).

### Reads incomplete only for iStat (gdu.51)

Fixtures (`SelfPositioningCompletenessTests`, `ObserverTests`, `LiveActuatorTests`, `LayoutEngineTests`): stale iStat only -> `.completeExceptSelfPositioning`; unnamed (fresh-process) timeouts attributed from the previous tree; a stale third-party item, an unexplained extra failed group, a top-level failure, a third-party app-side stale item -> `.incomplete`; a hide of a named dummy is judged `notHosted` on an exceptSelfPositioning read (not on an incomplete one, gdu.38 rule kept); live-verify poll verifies a dummy hide with every scan exceptSelfPositioning (no respawn), still falls back for another kind of incompleteness and for a self-positioning unit; observer agrees across scans differing only by stale iStat items and still refuses a stale third-party on-bar item; the engine ends an ORDER pass `unsettled` when a planned move involves a self-positioning key on an exceptSelfPositioning read, but moves other items. `make test`: 436 tests (baseline 414).

Live 2026-11-04 (Bartender 7 quit, MBDummy only, machine load 50-230): `mbprobe hide/show status:MBDummy::Dummy-A` x10 cycles = 20/20 ops `MECHANISM live`, MenuBarAgent pid constant (65492), no respawn. Per-op actuation ms and the read level of the deciding scan (`read level` in the actuator trace): hide 3221 complete, 1325 exceptSP, 1312 exceptSP, 979 complete, 1306 exceptSP, 1300 exceptSP, 958 complete, 1321 exceptSP, 1280 exceptSP, 3542 exceptSP; show 2896 exceptSP, 2524 complete, 978 complete, 1292 exceptSP, 2904 exceptSP, 992 complete, 2888 exceptSP, 2300 complete, 1297 exceptSP, 1305 exceptSP. 13 of 20 were decided on a read with iStat stale, all within 1.3-3.5 s (before: such reads were refused; the bead saw 17 s+ then a respawn). `scripts/soak-events.sh` (load 52): SOAK PASS, phase V 5/5 (max 3 s), H 6/6 (max 4 s), R 20/20 (max 12 s, no wait above 20 s), final 1/1, MenuBarAgent pid unchanged, 0 engine failures. End state: dummy stopped, Bartender 7 relaunched, third-party order identical to the start (21 on-bar items), every `trackedApplications` entry `isAllowed` equal to the backup (only the ad-hoc binary path of the MBDummy/Sommelier entries differs, macOS re-registers it), real `layout.json` absent.

### Long iStat streak (gdu.53) reviewer steps
Fixtures (`SelfPositioningCompletenessTests`): 10 consecutive iStat-only unnamed-timeout scans stay `.completeExceptSelfPositioning` and every one attributes (cap) ; a non-iStat unnamed timeout at scan 6 is `.incomplete` for that scan only; a vanished third-party element in a streak is `.incomplete`; iStat quitting prunes the record; a fresh process (cache from disk) attributes on its first scan. `swift test`: 481 tests (baseline 447).
Live (human/reviewer, NOT run by the implementer): with Bartender 7 quit and MBDummy running, the app on a scratch layout (`SOMMELIER_LAYOUT_FILE=<scratch>`), wait for an iStat streak (levels flip to exceptSelfPositioning), then `mbprobe list --json --debug --repeat 12` and note each scan's completeness: it must stay `completeExceptSelfPositioning` (never `incomplete`) beyond scan 4, scans staying near 0.7 s instead of ~2.5 s. During that streak run a dummy hide/show via `SOMMELIER_ARRANGE_MOVE` (as in the gdu.51 live steps): it must verify live within 1-5 s (`live: verified by complete read ... read level completeExceptSelfPositioning` in the log, no agent respawn). Expected log lines: `carried N item(s) forward as stale` for the first 3 scans, then `dropping ...: stale for 3 consecutive scans`, with scans still `completeExceptSelfPositioning`; `self-positioning groups: pid N no longer running; record pruned` only if iStat is quit.

### Forced MenuBarAgent restart (test only; run ONCE)
With the app on a scratch layout and converged (`SOMMELIER_LAYOUT_FILE=<scratch> build/Sommelier.app/Contents/MacOS/Sommelier`), `killall MenuBarAgent`
once; never during a drag (killing the app mid-drag leaves the mouse button down; `cliclick du:x,y` releases it). Measured 2026-11-04 17:23 (watcher poll 5 s
at that time): kill 17:23:04.14, launchd respawn 04.23 (pid 73223 -> 34707); a pass in flight across the respawn read `hostedComplete=false`, then two
complete reads with 4 stale on-bar items (no agreement), then agreement at 07.43 with `plan: converged actions=0` (no hide/move was planned from the
incomplete scans); watcher `agent restarted: pid 73223 -> 34707` at 07.91 (the next poll; the NSWorkspace notification never arrives for the agent);
`pass started 0 ms after agent restarted` at 10.01 (2 s settle), observations 11.60 (incomplete), 12.50, 12.97 (agree), `plan: converged` at 12.97 =
**8.7 s after the agent was back**, layout intact: the 15 compared on-bar items identical to before (iStat and heuristic items exempt), the 28 real
hidden items still not on the bar. Reviewer's independent run (poll then 2 s): kill -> watcher `agent restarted` 1.2 s -> converged 4.3 s after the kill. Because detection was poll-bound, the default poll was then lowered to 2 s (not re-measured: the restart is run once).

### Display change and sleep/wake (human-assisted; NOT run by an agent)
**Status: display unplug/replug and sleep/wake remain human-assisted and UNTESTED by the loop; the bead's done criterion for the display change is only partially met until a human runs the steps below.**
Display change: with the app running on the real layout and converged, open the overflow panel (left click the Sommelier item), then unplug an external
display (or change the resolution in System Settings > Displays). Expect in `build/sommelier.log` (run via `make app-run`):
`display configuration changed (N screen(s)); reconcile in 1 s`, `overflow panel repositioned after display change: {{x, y}, {w, h}}` (the panel follows
the item to its screen and stays inside that screen's visible frame), then ONE `pass started ... after display change`, and `plan: phase=converged` (or only
moves that restore the layout) within ~5 s; the Arrange window shows Converged. Replug: the same lines. Several notifications in a burst must produce one pass.
Sleep/wake: put the machine to sleep with Apple menu > Sleep (NOT `pmset sleepnow` from an agent), wake after ~1 min. Expect `willSleep: no new passes until
wake` before sleep, `didWake: reconcile in 3 seconds`, then `pass started ... after wake` ~3 s after wake, converged with the layout intact (an agent respawn
on wake additionally logs `agent restarted: pid A -> B`; the pass waits out its 2 s settle).
Also check by hand: launch a new third-party menu bar app that is not in the layout: Arrange status line shows `New item: <name> placed in Visible` (or Hidden per
the policy) for ~10 s and the log has the same text.

Scope: the soak asserts the order of THIRD-PARTY items and the dummies' states in every phase and the final check; system items (`module:*`, `status:com.apple.*`) are macOS-ordered (re-based on every agent respawn, not managed by Sommelier) and excluded, together with heuristic keys and iStat items.

Respawn rule: a MenuBarAgent pid change that the app log attributes to Sommelier's own hide fallback (`agent restarted by Sommelier (expected)` or `falling back to respawn`) makes its phase INCONCLUSIVE ("own fallback respawn (slow reads)", counted in the inconclusive column, not a failure; more than 3 inconclusive fail the soak); a pid change without such a line is a FAIL ("foreign respawn").

Live run 2026-11-04 19:0x-19:17 (Bartender quit): V 5/5, H 6/6, R 20/20, final 1/1; one own-fallback respawn (pid 22293 -> 46171) in reveal 10 after `live verify failed after 17626ms: 8 scans, 1 complete` (slow incomplete reads); it failed the then-strict rule, which is why the rule above exists.

Corrective soak run (2026-11-04 18:1x, baseline captured before the app starts and compared in full, every stop waits for an idle engine): V 5/5, H 6/6, R 20/20, final 1/1, no respawn, `SOAK PASS`. The app log of that run ends with `plan: phase=converged` before the stop (the last line is an observation-only poll pass); no kill happened inside a batch or drag. A first corrective run failed 3 times only because `module:WiFi` flickers out of the read; it is now excluded from the comparison like the other volatile modules.

Soak script corrections (corrective pass 2): the Wi-Fi exclusion used `$` inside a `grep -v` alternation, which macOS grep ignores, so Wi-Fi was still compared; the filter is now `grep -Ev` with one `-e` per pattern and a start-of-script self-test. Convergence waits are 90 s; a wait that ends while the latest observation in the app log is unsettled, incomplete or has stale on-bar items (e.g. `hostedComplete=false onBarStale=8`, all iStat items stale; the engine correctly does nothing) is recorded INCONCLUSIVE with the reason, shown in the summary and not counted as a failure; more than 3 inconclusive phases fail the soak. A failure to stop the app safely now sets the exit code (decided inside the EXIT trap). Final behaviour (script-only corrective passes 3-4): respawn attribution counts only app-log lines stamped at or after the soak's start (the pre-soak `build/sommelier.log` is discarded), and every phase check consumes the lines it saw, so a fallback line is never reused for a later phase's respawn; `scripts/soak-events.sh --selftest` (also run at every start) checks the volatile-key filter and that a fallback line from before the start yields "foreign respawn" while one after it yields "own fallback"; before stopping the app, the idle check is repeated after its 2 s quiet period (no `pass started` after the last converged plan, else it waits for that pass's plan, 60 s bound); only the Sommelier the script launched is stopped, by pid, and a Sommelier already running makes it exit 2 before touching Bartender or any dummy.

Final passing live run (2026-11-04 20:16-20:23, load 45-112, Bartender quit): `SOAK PASS (0 failures, 0 inconclusive)`, V 5/5, H 6/6, R 20/20, final 1/1, MenuBarAgent pid 65492 constant. The later script-only fixes (attribution window, pid stop, idle re-check, early running-app check) were self-tested but not re-run live.

## Release smoke (reviewer/human)
Status: **RUN 2026-11-04 (reviewer, partly headless); human steps below still needed.**
Observed:
- DMG: `spctl -t open` accepted (Notarized Developer ID), `stapler validate` OK. That run predates gdu.50: only the DMG carried a ticket. `make notarize` now also staples the `.app` itself (two submissions), so an offline first launch of a copied app has its ticket; the offline launch itself is still untested.
- Locally built artefacts carry no quarantine flag, so `com.apple.quarantine` was added to a scratch copy to mimic a download. `open` then showed the Gatekeeper dialog
  "'Sommelier' is an app created by the app Safari. ... Apple checked it for malicious software and none was found" (Cancel/Open). macOS ran it from an App Translocation path.
- The status item appeared and the onboarding window showed Accessibility "Not granted".
- A trusted run of the bundle's binary from the terminal logged `launch trusted=true` and `live hide/show: available` (the app-group entitlement IS honored in the notarized .app; findings-live-trigger section 8 case resolved).
- Hide verified live in 10.5 s (dominated by a stale-iStat scan streak; see the stale-iStat bead), show verified live in 5.2 s; MenuBarAgent pid unchanged.
- QA steps 1-3 ran headlessly.
Still to do by a human: grant Accessibility to the Finder-launched app and confirm it starts working without relaunch; panel and Arrange clicks; display change and sleep/wake.
Quit Bartender first; relaunch it afterwards.
0. Commit first: CFBundleVersion is the commit count, and `scripts/publish-release.sh --dry-run` must pass (clean tracked tree, DMG built from HEAD, embedded version == VERSION).
1. `make release VERSION=0.1.0 && make notarize` (or use an existing `dist/Sommelier-0.1.0.dmg`). Check `xcrun stapler validate dist/Sommelier.app` and `... dist/Sommelier-0.1.0.dmg` both pass, and
   `spctl -a -vv -t install dist/Sommelier-0.1.0.dmg` and `spctl -a -vv -t exec dist/Sommelier.app` say "accepted, source=Notarized Developer ID".
   Then `make check-scripts` (publish checks) and `scripts/publish-release.sh --dry-run`.
2. Mount the DMG (`open dist/Sommelier-0.1.0.dmg`), drag Sommelier to /Applications (or run it from `dist/`).
   Use `SOMMELIER_LAYOUT_FILE` only for the terminal-started variant; a Finder launch uses the real layout, so back it up first.
3. Launch from Finder (double-click). Expected Gatekeeper dialog: "Apple checked it for malicious software and none was found" with an Open button. Click Open.
4. The onboarding window appears. Grant Accessibility in System Settings (macOS 27: "Device Control and Data Access"); Sommelier should start working without a relaunch.
5. Confirm the app's own result (`mbprobe permissions` checks mbprobe, not the app): the onboarding/Settings state shows trusted. Do NOT use `log show`: NSLog text is
   redacted to `<private>` in release builds. For `launch trusted=true` and live hide/show availability, run the bundle binary from a terminal and read its stderr
   (`make app-run` style: `dist/Sommelier.app/Contents/MacOS/Sommelier 2>&1 | tee /tmp/s.log`). If live hide/show is unavailable, record that as the finding.
6. Start a dummy (`make dummy ARGS="--count 2"`), hide one dummy via the app (Arrange window or panel) with the live mechanism, verify with `make probe ARGS="list"` that it left the bar
   within 1-5 s and no MenuBarAgent restart happened, then show it again and verify.
7. Quit Sommelier, `make dummy-stop`, relaunch Bartender.
Record results (pass/fail, timings, Gatekeeper dialog text) here.

## Poll trigger (sommelier-e7t)

`PollTriggerTests` (18 tests, 520 total): iStat order flip / iStat vanishing, WiFi flicker, width-0 heuristic noise, MenuBarAgent heuristic + "Show Hidden" module: no trigger and no
confirming scan; a third-party item appearing or moving: trigger after the confirming scan (2 fast scans, 1 sleep); a one-scan flicker: confirmed away; fixed 10 s period (worst-case detection 11 s); heuristic-parked and stale-parked keys exempt; a change right after a pass (reference = the engine's published signature) is caught, also across an unsettled skip; skip while busy / hold / unsettled / within 5 s of a user action (no scan); pass starting during the confirmation cancels it.
Live (scratch layout, Bartender quit, converged 5 min): 0 poll passes (was ~28); `make dummy` -> pass 10 s later, 2 dummies placed in Visible; `make dummy-stop` -> pass 13 s later.

gdu.58 cap: `PollTriggerTests` +6 (fake clock): an F1/F2 two-state flapper -> 2 poll passes in the first minute, the suppression log exactly once with both keys, 0 passes through the 5 min window, resumption afterwards; a genuine change during suppression is not triggered by the poll; steady bar and one-change-per-minute are unaffected (no suppression, nothing reported); status line text; flapping keys. `steadyDisagreementWithOneRealChangeCostsExactlyOneExtraPass` now raises the cap (its fake clock never advances). 537 tests (baseline 531).

gdu.56 launch/quit for agent apps: `LaunchQuitTriggerTests` (6, injected `RunningAppsSource`): .accessory launch and quit each request one pass; notification + KVO within the debounce = one pass, a late notification re-arms a second; .prohibited and non-owner quits ignored, an owner's quit fires; a burst = one request. Live 2026-11-05 (4 samples): pass started 1.18-1.29 s after `make dummy` / `make dummy-stop`, one pass each, KVO path only (no didLaunch/didTerminate posted for the dummy); idle churn 2 passes in 2 min.
- [x] `make dummy` -> "app launch/quit" pass within 3 s (log shows `launch pid ... policy 1`); `make dummy-stop` -> quit pass within 3 s. Verified live 2026-11-05: 1.18-1.29 s, one pass each, KVO path (see the gdu.56 line above).

### Record pruning, record age, noise scoping (gdu.54) reviewer steps
Fixtures (`SelfPositioningCompletenessTests`, `LiveActuatorTests`): record {cpu, mem, disk} with disk gone from iStat's fresh extras and a read with cpu+mem+X unnamed timeouts -> `.incomplete` (kept when extras still list disk or iStat's extras read failed); a record older than `selfPositioningRecordMaxAge` stops attributing unnamed timeouts until a complete read (logged once; named timeouts unaffected); noise element + missing third-party element with no unnamed timeouts -> `.incomplete`; uncovered unnamed timeout reason names the missing non-iStat group; noise "left edge" is the strip's minX (strip at x = -1000); `expectToVanish` is set before the live hide write and cleared on verified, verify-failure, write-failure and no-live exits. `swift test`: 478 tests (baseline 468).
Live (HUMAN-only, NOT run by the implementer or an agent reviewer: it needs iStat Menus preferences changes): `mbprobe list --json --debug --repeat 12` while iStat is in a timeout streak, after removing one iStat item (for example Disk) in iStat's preferences; the log must show `self-positioning groups: pid N extras no longer list ...; pruned from the record` once (on a scan whose iStat extras read succeeded), and a third-party unnamed timeout in that state is reported `incomplete` with an `uncovered: ...` reason instead of the middle level. Restore the iStat item afterwards.

### No-flash hides (gdu.55) reviewer steps
Unit tests: `LiveActuatorTests` (gdu.55 section: 30 s without a usable read -> `liveUnverified`, assumed-hidden recorded, 0 restarts; readback never showing the value x3 -> `liveWriteFailed`, or one respawn when the flag allows; `setAllowedLive` throws -> same gating; missing entitlement -> respawn by default; unreadable store; symmetric show; fast hosted confirm during a streak; two contradicting complete reads -> failed, no restart), `LayoutEngineTests` (pending marker until a later complete read confirms; contradicted hide re-planned, not struck; `liveWriteFailed` -> failed, not retried). `swift test`: 510 tests (baseline 499). Old tests changed because they asserted timeout/verify-failure -> respawn: `liveTwoCompleteUnsatisfiedReadsFailWithoutRestart` (was `...FallBackToOneRestart`), `liveEightIncompleteReadsAreUnverifiedNotARespawn` (was `...ThenFallback`), `liveIncompleteForAnotherReasonIsUnverifiedNotARespawn`, `liveUnitThatIsSelfPositioningStillNeedsACompleteRead` (now liveUnverified), `coincidentalVanishWithAMatchingCountIsAmbiguous` (failed, no respawn), `expectedToVanishIsSetBeforeTheHideWriteAndClearedOnEveryExit` (restarts 0), `liveWriteThrowFallsBackToOneRestartWhenRestartIsAllowed` (needs the flag); `storeSayingShownOrNamedItemsAreNotShortCircuited` passes because the fake store now follows live writes.
Live (reviewer only, MBDummy items only, Bartender quit; NOT run by the implementer):
1. `make dummy ARGS="--count 2"`; note `pgrep -x MenuBarAgent` (the pid must not change below). Drive hides with `mbprobe hide|show` or the app.
2. Load the machine: `for i in 1 2 3 4; do yes > /dev/null & done`; kill them afterwards (`kill $(jobs -p)`).
3. 20 cycles of `mbprobe hide status:ie.boboco.mbdummy::Dummy-A` then `mbprobe show ...` (use the key as printed by `mbprobe list`); `pgrep -x MenuBarAgent` after each. Required: 0 pid changes over the 20 cycles. Every hide prints `MECHANISM live`, or, only when the reads were unusable in the window, `MECHANISM liveUnverified` plus `NOTE applied per Control Center store; confirmation pending`; never `respawn`.
4. Repeat 3 during an iStat streak (reads `exceptSelfPositioning`; the trace line `verified by fast hosted read` is expected, confirm within ~1 s): same 0 pid changes.
5. `scripts/soak-events.sh` phase R: 0 own-fallback respawns.
6. Settings > General shows "Allow menu bar restart as a last resort"; with the entitlement it is OFF by default (`defaults read ie.boboco.sommelier allowAgentRestart` unset or 0).
7. Arrange window: a `liveUnverified` hide shows a faded check mark with an orange dot (tooltip "Applied; confirmation pending") that becomes the plain check mark after the next settled complete read.

## Spacing (gdu.20)
Human checklist (Settings > Spacing):
1. Drag the Item spacing slider; the value is written only on release (`mbprobe spacing get` or `defaults -currentHost read -globalDomain NSStatusItemSpacing` shows it). Typing a number and pressing Return also writes; values clamp to 0...24.
2. Relaunch an app (or `make dummy-stop && make dummy`): its item width changes (about 24 + spacing). Running apps do not change; the menu bar is not restarted.
3. Selection padding: set 0 and 8, relaunch an app, click its item and compare the highlight size by eye (not measurable headlessly).
4. "Reset to system default": both keys are removed (`defaults ... read` says the key does not exist) and the labels show "default".
5. Confirm no menu bar flash happens at any point.

## App shell follow-ups (gdu.35)
Unit tests: `DropSelfTests` (own module name / bundle id / owner key / AX identifier dropped; "SommelierX", look-alike bundle ids and names kept; empty input) and `ConflictDuringPassTests` (`RobustnessTests.swift`: `FakeActuator.setAfterCall` flips `engine.setConflict("Bartender 7")` after the first of four moves: exactly one actuator call, outcome `.paused`, no `.failed` status, no `lastError`; after `setConflict(nil)` the next pass converges).

### Right-click menu (live verification PENDING; needs the running app, run by a live task or a human)
1. Quit Bartender. Start Sommelier with `SOMMELIER_DEBUG_MENU=1`; expect one log line `[Sommelier] menu titles: ... | ... ` listing the menu entries (status line, section toggles, Arrange..., Settings..., Quit; `[x]` marks checked items).
2. `swift scripts/check-rightclick-menu.swift` (read-only AX plus one CGEvent right-click and one Escape; do not touch the mouse meanwhile). Expect `menu titles:` matching the log line, a menu frame next to the status item, `PASS`. It exits 2 if the item is hidden or in the system overflow.
3. By hand: right-click the item: the menu appears at the item; Escape closes it; then LEFT-click the item: the overflow panel still toggles (the menu assignment is cleared after each right-click, `StatusItemController.showMenu`).
Checklist: [ ] log line seen  [ ] script PASS  [ ] left click toggles the panel after the menu closed.

### Bartender launches mid-pass
Unit-tested only (above). Live: start a long reorder (`make dummy ARGS="--count 8"`, scramble the layout in Arrange), launch Bartender 7 during the pass; expect `conflicting manager running (...); pass ends before the next actuator call` in the log and no further `drag` lines; quitting Bartender resumes passes. Pending a live run.

## Main-menu entries dropped (gdu.29)
Unit tests (`MenuBarScannerTests`): main-menu elements dropped, genuine parked (x 2, y 1204, w 24) and a zero-width genuine hosted item unchanged; timed-out main-menu group not a failure; old cache records ignored on load.
Live `mbprobe list` (read-only), count of Apple/File/Edit/.../`_NS:` entries and total `x=` rows: Finder front 0 (50 rows), TextEdit front 0 (48), Safari front 0 (50); the only `heuristic:com.apple.MenuBarAgent` row is the unnamed "System item" button (x=774). "Before" was also 0 live: the running agent did not mirror the main menu during this session (see docs/findings-identity.md, gdu.29); the 7-8 entries were recorded in docs/evidence/ax-b-drag-unrelated.txt.

README screenshots (sommelier-gdu.63): Bartender quit, `make dummy ARGS="--count 2"`, scratch layout from `mbprobe layout init-from-current --file <scratch>/layout.json` with Dummy-A/B moved to the front of `hidden`, app run with `SOMMELIER_LAYOUT_FILE=<scratch>/layout.json` (plus `SOMMELIER_OPEN_ARRANGE=1` for the Arrange window); click the Sommelier item (mouse-down >= 70 ms) and `screencapture -x -o -l <window id>` for each window (Arrange then `sips -Z 1400`), saved as `docs/images/panel.png` and `arrange.png`.

## Inline reveal: "show the rest" mode 1 (gdu.15)
Unit tests (`RevealTests.swift`, 9): planner flags (hidden appended in layout order, always-hidden only with `showAlwaysHidden`, hide units, clearing re-hides),
`RevealController` (debounce 300 ms, re-hide on click while revealed, `revealedObserved` only after the pass), engine (`revealedObserved` set after convergence, not on
request; a reveal whose actuator calls all fail is never reported as revealed). `make test`: 636 tests (baseline 627).

Live 2026-11-05 (Bartender 7 quit, MBDummy `--count 2`, scratch layout via `SOMMELIER_LAYOUT_FILE` = `mbprobe layout init-from-current` with the Dummy unit in `hidden` and every
real hidden item moved to `alwaysHidden`, `defaults write ie.boboco.sommelier revealMode inline` / `autoRehideSeconds -int 5`, real clicks at 70-90 ms hold with
`clk`/`clko` at the Sommelier item (x 989, w 23, y 15)). Both plists backed up first. The bar is naturally full: the dummies land in the system overflow (stacked behind the chevron),
so "on the bar" is judged with `mbprobe list` (on bar = flagged `overflow`, not parked), not by sight.
* Click -> reveal converged (`reveal converged N ms after the click` in the app log): 2152, 3511, 2852 ms (further samples 4057, 3055, 4528, 4730). TARGET 1.5 s NOT MET with 2 items:
  the pass needs two agreeing scans (~1.7 s of observation before the first write) plus ~1.1 s of live write and verification. Re-hide after the click (request -> observed hidden): 4.4 s once, 1.6 / 3.8 / 1.6 s for the idle re-hide.
* **gdu.71 live re-measurement (2026-11-05, reviewer, from the wt/gdu71 build; Bartender quit, MBDummy x2, scratch layout, inline mode, 80 ms plain clicks). TARGET 1.5 s NOT MET in the realistic cycle.** Read `reveal converged N ms after the click observe=Mms reuse=...` and the engine line `observe=<ms> scans=<n> reuse=...`; `userPassReuseWindow = 0` gives the A/B baseline.
  * Cycle A (click after >= 16 s idle): A1 observe 3042 ms / scans 2 / reuse=no / click->converged 6456 ms; A2 3632 / 3 / no / 6994 ms; A3 2931 / 2 / no / 3779 ms. The auto re-hides 5 s later were reuse=no too (outside the 2 s window, correct).
  * Cycle B (re-hide clicked 0.5 s after the reveal converged, then a reveal 0.5 s after the re-hide landed): B1 re-hide observe 2274 ms / 1 / yes; second reveal 82 ms / 1 / yes; click->converged 3874 ms (verify 2960 ms). B2 re-hide 448 / 2 / no (seed offered, the fresh scan disagreed, the fallback worked); second reveal 256 / 1 / yes; click->converged 1622 ms (verify 748 ms). B3 re-hide 2287 / 1 / yes; second reveal 71 / 1 / yes; 3884 ms (verify 2955 ms). The first idle reveals in B: 1309, 4994, 1691 ms, all reuse=no.
  * Why the target is not met: (1) a seed exists only within 2 s of a previous pass and the poll's visible-only scan cannot seed, so a click after idle never reuses (follow-up bead sommelier-gdu.77: refresh `lastAdopted.at` when the poll finds the bar unchanged); (2) a single full scan costs 0.07-2.3 s depending on iStat's AX replies, so scan TIME, not scan count, dominates observe (reuse=yes cut the count to 1, and the reuse=yes second reveals did take 71-256 ms); (3) post-write verification takes 0.75-2.96 s (about 2.96 s whenever iStat is stale), is out of scope by this bead's done criteria (gdu.55 rules unchanged), and alone can exceed the target; the target was reached only when iStat answered quickly (B2: 1622 ms, verify 748 ms, still just above 1.5 s).
* **gdu.77 live (2026-11-05, from the main checkout build; Bartender quit, MBDummy x2, scratch layout, inline mode, 80 ms plain clicks after an Option check; poll refreshes the adopted observation's age). Reuse achieved; the `observe < 500 ms` criterion was NOT met.** Clicks after >= 18 s idle (no pass in between except the 10 s polls):
  | click | observe | scans | reuse | click->converged | note |
  |---|---|---|---|---|---|
  | 1 | 667 ms | 1 | yes | 2541 ms | scan level complete-except-self-positioning |
  | 2 | 2283 ms | 1 | yes | 4105 ms | iStat stale |
  | 3 (second run, log line `poll: bar unchanged since the adopted observation; ...` seen before the click) | 2295 ms | 1 | yes | 3689 ms | iStat stale |
  | 4 (second run) | 2469 ms | 1 | yes | never (see incident) | iStat stale |
  (A fifth click, 1.9 s after a launch/quit-triggered pass, is not an idle click: 771 ms / 1 / yes.) gdu.71 had reuse=no and observe 2.9-3.6 s for these clicks; the poll now keeps the seed alive (4 of 4 reuse=yes, scans 2 -> 1). The remaining observe time is the ONE fresh full scan itself: 0.7-0.9 s when iStat answers, 2.3-2.5 s when it is stale (see docs/findings-live-trigger.md, "Post-write verification cost"). The 71-256 ms of gdu.71 were only reachable when the fresh scan ran with iStat answering and capped. Verification after the write: 713-1526 ms (fast/complete read #1), 3500 and 4065 ms when a full scan hit the iStat timeouts.
  * INCIDENT (stop-worthy, not caused by the seed): on click 4 the reveal's two dummies pushed real items between the drawn bar and the system overflow pile on this naturally full bar; the re-plan then saw "order" drift (8 actions) and the engine DRAGGED real items (TimeMachine, KeepingYouAwake, TextInputMenuAgent, Jump Desktop ...; several drags verified, several failed with "menu opened"), and a later pass wrote `isAllowed=true` for the real, Bartender-hidden item `co.podzim.boltai-mobile`. The run was stopped at once (Sommelier killed). BoltAI's `isAllowed` and the dummy's were restored (`mbprobe cc-allowed set ... --live`, Bartender quit), the real order store (`com.apple.MenuBar.plist`) was NOT backed up and the real items' bar order may therefore differ from before the run (the scratch layout's 6 pending order moves are not applied). Lesson for the procedure: also back up `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`, and stop after any `plan: phase=order` in a reveal pass. Follow-up bead proposed: a reveal/re-hide pass on a bar that overflows must not plan order drags of items in the system overflow pile or items outside the scratch layout's intent.
* Icon: `wineglass` -> `wineglass.fill` exactly at `observed=true` in the log, back to `wineglass` once the re-hide pass has landed (never at the request).
* Order (`mbprobe list --include-self`): hidden: 30 on bar, 22 parked, Dummy-A/B parked; revealed: 32 on bar, 20 parked, Dummy-A/B on the bar (overflow area); re-hidden: 30/22,
  Dummy-A/B parked. The hash of the DRAWN non-dummy order was identical before and after each cycle (`fecfa0f1` / `a85715a4`; two stable values because the width of the stacked
  overflow pile changes which items are drawn, with dummies shown 17 drawn, hidden 17 or 19).
* Auto re-hide: 5 s idle after convergence (`re-hide: idle 5 s` 5.05 s / 5.00 s / 4.95 s after converged). Click on a real menu bar item (Jump Desktop) while revealed ->
  `idle timer suspended`, Escape -> `re-hide: menu bar item menu closed` 0.6 s later. Click on the Sommelier item while revealed (1.2 s after converged) -> `rehidden` at once.
* Plain click with the Dummy unit in `alwaysHidden`: nothing to reveal, dummies stay parked, icon stays hollow, the request is withdrawn after 20 s (`reveal never converged`).
* Option-click (the CGEvent `flags` of a posted click are not delivered to the button action; the click handler therefore also reads `NSEvent.modifierFlags`): detected
  (`option=true`), `showAlwaysHidden` requested, the engine planned `membership actions=22` = the whole always-hidden section. NOT run to completion on purpose: every real hidden item
  is in always-hidden in the scratch layout, so a completed option reveal would have shown the user's real items. The batch was refused before any write
  (`unsupportedItem: macOS has no Control Center entry for this app yet`), nothing moved (22 still parked). Dummies-only always-hidden reveal is covered by the planner/engine unit tests.
* End state: Sommelier and MBDummy stopped, Bartender 7 relaunched; `com.apple.controlcenter.plist` byte-equal; `group.com.apple.controlcenter.plist` `trackedApplications` equal entry by entry
  after restoring MBDummy `isAllowed` (`mbprobe cc-allowed set ie.boboco.mbdummy 1 --live`, Bartender quit while writing); `com.apple.MenuBarAgent.plist` differs only in
  `MenuBarAnalytics.lastReportedTrailingItemCount` (22 -> 24); real `layout.json`/`slot-hints.json` sha unchanged. A real item (DEVONthink) was shown once in the first run because the engine
  adopted it as a new item into Hidden in the scratch layout; fixed by moving it to `alwaysHidden` and it was re-hidden by the engine (parked again at the end).

Reviewer steps: scratch layout as above; `defaults write ie.boboco.sommelier revealMode inline`; click the Sommelier item; expect `reveal converged`, `wineglass.fill`, Dummy-A/B on bar in `mbprobe list`, re-hide after 5 s idle,
click-while-revealed re-hide, `defaults delete ie.boboco.sommelier revealMode` afterwards.

WARNING (Option latch): posting Option-flagged mouse events (the `clko ... opt` helper) can latch the Option modifier system-wide. Before any plain click check
`NSEvent.modifierFlags` / the `global flags` value in the app log line `reveal click (option=..., event flags .., global flags ..)` (0x80000 = Option held); if latched,
release it (`osascript -e 'tell application "System Events" to key up option'`) before clicking. Never option-click with real items in always-hidden.

Corrective live re-check 2026-11-05 (untracked key; Bartender quit; scratch layout: Dummy unit AND `status:at.obdev.littlesnitch.agent::Item-0` (parked, NO Control Center entry per `mbprobe plan --show-hidden`, which also showed 8 real untracked keys skipped
with "cannot be shown: not tracked by Control Center" and 13 shows for the tracked ones) in `hidden`, every other real hidden item in `alwaysHidden`): 3 clicks -> plan `membership actions=2 skipped=1` (the dummies shown, Little Snitch skipped), converged after
3514 / 3199 / 1324 ms, icon `wineglass.fill` at `observed=true`, Dummy-A/B on the bar (32 on bar, 20 parked), Little Snitch still parked, idle re-hide 5 s later back to 30 / 22 with the drawn non-dummy order hash unchanged. Plist
comparison: `com.apple.controlcenter.plist` byte-equal, `trackedApplications` equal after restoring MBDummy `isAllowed`, `com.apple.MenuBarAgent.plist` unchanged, real layout.json/slot-hints.json sha unchanged. `make test`: 640 tests.

Activation captions (gdu.70): a successful overflow activation with a note (`overflowStripStillExpanded`, `menuStillOpenAtCap`, `overflowStripStateUnknown`) shows a short neutral grey caption under the entry for 4 s; unit-tested via `ActivationCaption.make`; the panel rendering itself is not live-verified.

## Helper keys hide through the parent entry (gdu.68)

Live 2026-11-05 (Bartender 7 quit, MenuBarAgent pid 21399 constant, both plists backed up). The "untracked" parked items are helper processes listed in the `menuItemLocations` of a parent app's entry (`mbprobe cc-allowed list` prints them as `items=[...]`):
| item key | Control Center entry that governs it | isAllowed |
|---|---|---|
| `85C27NK92C.com.flexibits.fantastical2.mac.helper` | `com.flexibits.fantastical2.mac` | 0 |
| `86Z3GCJ4MF.com.noodlesoft.HazelHelper` | `com.noodlesoft.Hazel` | 0 |
| `com.houdah.HoudahSpot4.HoudahSpotHelper` | `com.houdah.HoudahSpot4` | 0 |
| `com.stairways.keyboardmaestro.engine` | `com.stairways.keyboardmaestro.editor` | 0 |
| `at.obdev.littlesnitch.agent` | `at.obdev.littlesnitch` | 0 |
| `heuristic:com.robinlu.mac.Tooth-Fairy` | own entry `com.robinlu.mac.Tooth-Fairy` (the heuristic key was wrongly treated as untracked) | 0 |
| `com.apple.ScriptMenuApp` | own Apple entry, refused (Apple apps are managed only in System Settings > Menu Bar) | 0 |

One-helper live test (HoudahSpot, the only key touched): `mbprobe cc-allowed set com.houdah.HoudahSpot4 1 --live` (before: 0, hosted element count `mbprobe overflow` = 23, helper frame parked x=2) -> within 3 s hosted=24 and the helper item is on the bar (x 798, in the system overflow stack); `... 0 --live` -> hosted=23 again within 3 s, readback 0 (cycle run twice: the first time without the hosted count). So the parent entry IS the hide unit of its helpers. Caveat: after the cycle the helper's own AX frame stays at the stacked position (x 798) instead of returning to the parked x=2 until the helper relaunches, so `mbprobe list` shows it `overflow`/on-bar although it is hidden (same stale-frame behaviour as the dummies; detection by "seen hosted" needs a hosting history that a helper in the overflow stack never gets). Restored to the original value.
`TrackedEntryResolver` (SommelierCore) is the single mapping used by `CapabilityRules` (planner/Arrange) and `ActuatorPlatform.trackedKey` (actuator): own entry first, else the single non-Apple entry listing the id, ambiguous -> none. `mbprobe plan --show-hidden` against the real layout (read-only) went from 14 skipped to 1 untracked (Script Menu) plus the overflow ones; hide/show of the dummies still `MECHANISM live` (1022 ms / 2803 ms). `make test`: 659 tests. End state: dummies stopped, Sommelier never started, Bartender 7 relaunched, `trackedApplications` decoded-equal to the backup (76 entries), `com.apple.controlcenter.plist` byte-equal, real layout.json untouched.

Partial batches (gdu.72): a batch with a unit the capability rules refuse writes the applicable units once and reports the refused unit per item (`LiveActuatorTests.batchSplitsRefusedUnitsAndWritesTheRestOnce`, `LayoutEngineTests.partiallyRefusedBatch...` / `allRefusedBatch...`; no live check, code-only). `make test`: 652 tests.
- [ ] Partial reveal (an untracked or Apple item parked in Hidden): Arrange status line shows "N items could not be shown" while revealed, nothing once re-hidden; a struck-out (failed) item does not stop the other hidden items from showing.
