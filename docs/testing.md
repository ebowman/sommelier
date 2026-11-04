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
now-retrying hosted read dominate; so typical panel click -> menu is 1-3 s, the target is NOT generally met (follow-up: cache the locate scan).
Reviewer's Keyboard Maestro case: a mis-aimed reveal fell back to AXPress and the menu appeared at an unrelated place (the fallback caveat).
Fixes this pass: landing needs a SETTLED frame (y 0...5, identical +-1 pt on two polls 50 ms apart) plus the agent hosting one more item;
the hosted baseline is read after the hold, right before the write; an incomplete hosted read never lets a stale frame be believed (retry, then
AXPress `axPressParked` for left, unavailable for right); a click or press that opens no menu within 1.5 s returns `.failed(.noMenu)` (re-hide and
hold release still happen). Moom x4 with `--escape-after 5`: 4 of 4 opened under the item; an earlier x6 batch with the old rules produced 2 `no
menu` failures that were AXPress fallbacks on a stale frame (the hosted fast read was incomplete), which is why the baseline read now uses the
retrying tree read. The panel's inline red caption is drawn under the outlined entry (tooltips do not show on a non-activating panel); live check:
a not-running Tot refreshed the entries (entry gone, log `failed: the app is not running`), so the caption itself was only seen by the reviewer's
outline run. `mbprobe activate` refuses while a Sommelier process runs (no engine hold) unless `--force`.


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
Fixtures (`SelfPositioningCompletenessTests`): 10 consecutive iStat-only unnamed-timeout scans stay `.completeExceptSelfPositioning` and every one attributes (cap) ; a non-iStat unnamed timeout at scan 6 is `.incomplete` for that scan only; a vanished third-party element in a streak is `.incomplete`; iStat quitting prunes the record; a fresh process (cache from disk) attributes on its first scan. `swift test`: 468 tests (baseline 447).
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
- DMG: `spctl -t open` accepted (Notarized Developer ID), `stapler validate` OK. Only the DMG carries a stapled ticket; the `.app` has none of its own. Fine online; an offline first launch is untested (follow-up bead exists).
- Locally built artefacts carry no quarantine flag, so `com.apple.quarantine` was added to a scratch copy to mimic a download. `open` then showed the Gatekeeper dialog
  "'Sommelier' is an app created by the app Safari. ... Apple checked it for malicious software and none was found" (Cancel/Open). macOS ran it from an App Translocation path.
- The status item appeared and the onboarding window showed Accessibility "Not granted".
- A trusted run of the bundle's binary from the terminal logged `launch trusted=true` and `live hide/show: available` (the app-group entitlement IS honored in the notarized .app; findings-live-trigger section 8 case resolved).
- Hide verified live in 10.5 s (dominated by a stale-iStat scan streak; see the stale-iStat bead), show verified live in 5.2 s; MenuBarAgent pid unchanged.
- QA steps 1-3 ran headlessly.
Still to do by a human: grant Accessibility to the Finder-launched app and confirm it starts working without relaunch; panel and Arrange clicks; display change and sleep/wake.
Quit Bartender first; relaunch it afterwards.
1. `make release VERSION=0.1.0 && make notarize` (or use an existing `dist/Sommelier-0.1.0.dmg`). Check
   `spctl -a -vv -t install dist/Sommelier-0.1.0.dmg` and `spctl -a -vv -t exec dist/Sommelier.app` say "accepted, source=Notarized Developer ID".
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

### Record pruning, record age, noise scoping (gdu.54) reviewer steps
Fixtures (`SelfPositioningCompletenessTests`, `LiveActuatorTests`): record {cpu, mem, disk} with disk gone from iStat's fresh extras and a read with cpu+mem+X unnamed timeouts -> `.incomplete` (kept when extras still list disk or iStat's extras read failed); a record older than `selfPositioningRecordMaxAge` stops attributing unnamed timeouts until a complete read (logged once; named timeouts unaffected); noise element + missing third-party element with no unnamed timeouts -> `.incomplete`; uncovered unnamed timeout reason names the missing non-iStat group; noise "left edge" is the strip's minX (strip at x = -1000); `expectToVanish` is set before the live hide write and cleared on verified, verify-failure, write-failure and no-live exits. `swift test`: 478 tests (baseline 468).
Live (HUMAN-only, NOT run by the implementer or an agent reviewer: it needs iStat Menus preferences changes): `mbprobe list --json --debug --repeat 12` while iStat is in a timeout streak, after removing one iStat item (for example Disk) in iStat's preferences; the log must show `self-positioning groups: pid N extras no longer list ...; pruned from the record` once (on a scan whose iStat extras read succeeded), and a third-party unnamed timeout in that state is reported `incomplete` with an `uncovered: ...` reason instead of the middle level. Restore the iStat item afterwards.
