# Findings: order drift after MenuBarAgent restarts (bead sommelier-gdu.9, corrective pass)

Machine: macOS 27.0.1, Bartender 7 quit. Tools: `mbprobe agent-restart`, `mbprobe hide/show/move`, the order store
(`com.apple.MenuBar.plist` -> `TrailingItemPreferredPositions`), `mbprobe list --json`. Reviewer symptom: the soak's restore check
failed because 7 fresh iStat items ended in different positions than the baseline after a run of hide/show restarts.

## The two iStat key sets
`status:com.bjango.istatmenus.status::<module>` (bundle form, "BJ") and `status:iStat Menus Menubar::<module>` (executable form, "EX")
both exist in the store with different values (BJ cpu 327 / time 99 / weather 562; EX cpu 602 / time 270 / weather 1469).

## Hypotheses tested

**A. MenuBarAgent resolves iStat's owner key inconsistently across restarts (a different value set wins each time).**
Plain restarts, no other change (`mbprobe agent-restart`, 5 times, order read with a full scan after each):
the observed iStat order (weather network disks battery sensors memory cpu time) equals the BJ-value order in 5/5 runs and
never equals the EX-value order. The EX values never changed in any run (602/270/1469 before and after every restart, hide/show
cycle and drag in this investigation). **Rejected: the bundle-id form always wins; EX is inert.**

**Harmonizing the sets (experimental, original bytes kept in the scratchpad, EX values written back afterwards).**
EX set to the BJ values, then 5 more restarts: order identical in 5/5 (and, trivially, now matching both sets). Plain restarts
were already stable, so harmonizing cannot be the fix; **not implemented** (and a writer that copies values between owner forms
would touch keys of apps we do not own).

**B. iStat re-registers items from its legacy `NSStatusItem Preferred Position` defaults.**
Legacy values (weather 10934, network 428, battery 384, disks 384, sensors 300, memory 282, cpu 199, time 120) give the same
order as the observed one except the disks/battery tie, which the BJ store values decide (disks 495 > battery 470, observed
disks before battery in every run). The store values, not the legacy ones, decide. **Not supported.**

## Per-run records of the restart experiments
Order = iStat items sorted by x from a full `mbprobe list --json` ~4-5 s after `mbprobe agent-restart`; `*` = the item was
reported stale (cached frame) in that read. "BJ match"/"EX match" = observed order equals the descending-value order of that
key set (restricted to the observed items).

Plain restarts (no change to the store; BJ cpu 327, weather 562, time 99 and EX cpu 602, weather 1469, time 270 at the start):

| run | observed order | BJ match | EX match |
|---|---|---|---|
| 0 (before) | weather network disks battery sensors memory cpu time | yes | no |
| 1 | weather network disks battery sensors memory cpu time | yes | no |
| 2 | weather network disks battery sensors memory cpu time | yes | no |
| 3 | weather* network* disks* battery* sensors* memory* cpu* time* | yes | no |
| 4 | weather* network* disks battery* sensors* memory cpu* time | yes | no |
| 5 | weather* network* disks battery* sensors* memory cpu* time | yes | no |

The values read after these five restarts (and one extra move) were still BJ cpu 327 / weather 562 and EX cpu 602 / weather 1469:
plain restarts rewrite nothing.

Harmonized sets (all eight EX values overwritten with the BJ values: cpu 349, weather 739, time 97 at that moment), 5 restarts:

| run | observed order | BJ match | EX match | EX cpu / BJ cpu / EX weather / BJ weather after |
|---|---|---|---|---|
| 1 | weather network disks battery sensors memory cpu time | yes | yes | 349 / 349 / 739 / 739 |
| 2 | weather* network* disks* battery* sensors* memory* cpu time | yes | yes | 349 / 349 / 739 / 739 |
| 3 | weather* network* disks* battery* sensors* memory* cpu* time* | yes | yes | 349 / 349 / 739 / 739 |
| 4 | weather network disks battery sensors memory cpu time | yes | yes | 349 / 349 / 739 / 739 |
| 5 | weather network disks battery sensors memory cpu time | yes | yes | 349 / 349 / 739 / 739 |

Stable in 5/5 (but plain restarts were stable before harmonizing too, so the harmonizing changes nothing). The EX values were
written back to their original numbers afterwards (cpu 602, time 270, weather 1469 verified).

## What actually changes the order: the agent re-bases stored values whenever the set of items changes
Store values are pixel-like distances from the trailing edge and are rewritten by MenuBarAgent, for ALL owners, whenever an
item disappears/reappears (hide/show restarts) or is dragged. Evidence (dummy items A/B, 3 hide+show cycles, nothing else touched):

| | before | after cycle 1 | cycle 2, 3 |
|---|---|---|---|
| BJ memory / cpu / time / weather | 382 / 327 / 99 / 562 | 322 / 267 / 69 / 502 | unchanged |
| EX cpu / weather | 602 / 1469 | 602 / 1469 | unchanged |
| Dummy-A / Dummy-B | 783 / 813 | 724 / 694 | unchanged |

Hide+show+move loop (8 cycles): BJ cpu 267 -> 349 and BJ weather 502 -> 739 between cycles 2 and 3; Dummy-A/B 694/724 ->
392/422 -> 595/565 -> 565/595. After the loop the dummies had left their original slot (just right of Wi-Fi) and sat between iStat
Memory and iStat CPU. iStat's items are interleaved with other apps' items (GateOpener between iStat Sensors and Memory, Signal
between CPU and Time), so a re-based value that moves one item past a neighbour changes the position of a whole group. iStat's item
widths follow live readouts, and several of its items are stale (cached frames), which makes the re-based values drift further.
**Root cause: stored positions are re-based by the agent on each restart that changes the item set; relative order of items
across owners is not preserved by the agent.** A plain restart (no set change) does not rewrite any value (5/5 and 5/5 above).

## Additional evidence: ALL owners' values are re-based, iStat's in the opposite direction
Store diff between the original file and the file after one failed soak (Bartender not running): modules and most apps shrank
(WiFi 923 -> 583, TimeMachine 674 -> 392, KeepingYouAwake 599 -> 295, TextInput 627 -> 323) while every bundle-form iStat
value grew (weather 562 -> 739, network 513 -> 690, disks 495 -> 672, cpu 327 -> 510). iStat's items are slow/stale under AX
and have legacy `NSStatusItem Preferred Position` values (weather 10934 = "far left"); after the soak the iStat group sat LEFT of
Wi-Fi (x 1042-1171 vs Wi-Fi 1219), originally it sat right of Audio/Video, Text Input and KeepingYouAwake. So the stored
values are re-derived by the agent per restart from where items currently are, and iStat is re-registered/re-laid-out
differently from everyone else (consistent with hypothesis B being a contributing factor, but not provable here because plain
restarts without a set change keep the values and the order).

## iStat repositions itself on plain restarts (why iStat is excluded from the drift check)
Plain `mbprobe agent-restart` x4, store untouched, full order of the fresh non-stale items after each (Bartender quit):
iStat Time sat after `signal`/before `com.corsair.ControlCenter` at base, after `signal` and before corsair... in restart 1
(`signal IS:time corsair`), and after `mcpmaestro` (before FloTile) in restarts 2-4, while every non-iStat item kept its order.
With an identical store, one iStat item took three different slots; its siblings are mostly stale so it is hard to see more. The
store cannot repair this (writing the old values back and restarting did not restore iStat in the second review's soak: 8 repairs
triggered, all by iStat/self-positioning relocations). `LiveActuator.Config.selfPositioningOwners` (iStat's two owner-key forms)
are therefore excluded from the drift check; their on/off-bar state is still covered by the collateral check, and the soak script
leaves `istatmenus` keys out of its restore comparison.

## Fix (implemented in `LiveActuator.applyHiddenBatchDetailed`)
1. Before the single `isAllowed` write/restart, snapshot the order store (`store0`) and compute the pre-restart layout: all
   non-heuristic status/module items on the bar (stale ones included: their store value is their slot, their cached frame is not
   trusted) plus the items about to be shown (a parked item keeps its value), minus the items being hidden, sorted by store value.
2. After the restart and the normal verification, compute the same ordering from the post-restart store. If the relative order of
   the common items differs ("drift"), write the pre-restart `store0` values back for those items (modules included, only for
   values the agent itself re-based; the normal API still refuses `module:` keys), restart once more, settle and re-verify.
   Only happens when drift is detected; no extra restart otherwise.
3. The collateral check counts only fresh "on the bar before -> off the bar after" changes that persist in a second settled full scan.
Harmonizing owner-key forms was not needed (plain restarts are stable with or without it) and is not done.

Limitation: the order comparison trusts the order store, not frames; if the agent lays items out differently from its own store
the repair does not notice. The soak's restore check compares fresh items by frame order and catches that.

## Further noise sources found while hardening the soak (second review pass)
* **Frame order of identifier-less items is not evidence**: with an unchanged store, `signal` and `GateOpener` (both `Item-0`, no AX
  identifier, attributed by frame join) swapped places between scans. The frame-based drift check therefore only uses items that
  have an AX identifier, are fresh and are not self-positioning (iStat).
* **Stale items must not steer a drag**: stale items keep cached frames from an earlier layout and sorted to the far left of the
  bar order; `LiveActuator` now picks the hover neighbour and the leftmost/rightmost slots from fresh items only.
* **Focus module** (`module:com.apple.menuextra.focusmode`, a heuristic module name that follows system state) changed its position
  relative to other items once between baseline and final; the soak's restore comparison leaves `module:com.apple.menuextra.*` keys out.
* **Drag reliability is environment dependent**: in some runs a Cmd+drag between two adjacent dummies failed on both attempts
  (frame logged: subject x=1346, target x=1376, toX=1398; or x=1487/1517, toX=1539) and in others the identical plan worked
  20/20; a manual `mbprobe drag --to-x` sweep (dx 0/6/14/24, 3 trials each) at that spot gave 0/3, 1/3, 0/3, 0/3, i.e. parameter
  independent. No cause was found (the earlier gdu.7 experiments at x~1077 were 53/53). The actuator reports these honestly as
  `notVerified` after the retry and the fallback.

## Scan agreement noise, gdu.46

Why: in 2 of 7 launches the engine never obtained an agreed observation for 3+ minutes ("scans did not agree after 6 attempts").
Study 2026-11-04, Bartender 7 running, MBDummy not running, 15 x `mbprobe list --json --debug` (one process each, ~2 s apart;
raw files were in the session scratchpad). Consecutive pairs: on-bar ORDER of the keys present in both scans differed in 0 of 14
pairs; the SET of on-bar keys differed in 8 of 14. Three scans (3/15) had an incomplete hosted read (8 failed reads, 24-28 elements
instead of 32-36), all with the 8 iStat items carried forward as stale.

| key | kind of flicker | frequency (15 scans) | root cause |
|---|---|---|---|
| `module:WiFi` | whole item present/absent; x 1074 -> 1044 when it is present | present 6/15 (absent in all of scans 7-15) | the agent's hosted tree drops the leftmost system modules between reads (32 elements instead of 35-36, no read error); the bar position moves ~30 pt when Bartender's `GoldenGateBar` / Focus come and go |
| `module:com.apple.menuextra.focusmode` | whole item present/absent | present 4/15 | same as Wi-Fi (heuristic-confidence key) |
| 8 x `status:com.bjango.istatmenus.status::*` | all eight stale on the bar together | 3/15 | iStat's AX read times out (`AX read failed for iStat Menus Menubar ... timed out`, 6/15; its hosted group too), so the scanner carries the previous items forward as stale (`maxStaleScans` 3). Order and widths did not change in this study |
| `status:com.surteesstudios.Bartender::GoldenGateBar` | appears/disappears | 14/15 | Bartender's own item |
| `status:com.apple.systemuiserver::...TimeMachine` | stale once | 1/15 | one timed-out SystemUIServer read |
| `module:WiFi`, `module:com.apple.menuextra.focusmode`, `module:AudioVideoModule` | the same key listed TWICE in one scan | 0/15 in `mbprobe`; seen once in ~40 engine passes (launch 4 of the first 10-launch run: first scan after a complete one, with the 8 iStat items stale) | NOT confirmed. Hosted dedupe in `MenuBarScanner.assemble` only collapses elements with identical frame, identifier, description AND title, so a group read and a button read of one module that differ in any of them both survive; the `missing(tree)` carry-forward in `readHosted` (previous element not found by `identityKey`) is the other candidate. Harmless now: `AgreedScanObserver` collapses duplicate keys (first by position, fresh over stale) and logs the copies |
| identifier-less items (signal, GateOpener, ToothFairy) | swap places | not seen in these 15 scans | frame-join attribution (findings-drag gdu.25 section); excluded from the ORDER part of the signature, still counted for presence |

Consequences. (1) The old signature (on-bar order + parked set, any stale item blocks) could only agree while Wi-Fi/Focus kept their
state AND iStat's read did not time out in either of two consecutive scans; a full scan with an iStat timeout takes ~2.6 s (a clean
one 0.6-1.5 s), so a run of stale scans alone costs 8-10 s. (2) Nothing in the data is an ORDER flicker of identified third-party items.
(3) The first observation is dominated by iStat read time: in 10 launches the first scan was complete 7 times; in 3 launches the first
2-4 scans were incomplete.

Rule now (`AgreedScanObserver`, docs/architecture.md "Observer"): order of identified, non-heuristic, non-self-positioning keys; presence
of everything else; Wi-Fi and Focus exempt altogether; on-bar stale still blocks; stale parked items are compared as a set;
duplicates collapsed. After `maxScans`/`deadline` the latest COMPLETE read is returned unsettled instead of an error.
