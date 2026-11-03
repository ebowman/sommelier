# Findings: synthesized Cmd+drag reorder (bead sommelier-gdu.7)

Code: `Sources/SommelierCore/DragMover.swift` (DragMover, DragPlan, ItemResolver, DragTarget),
`mbprobe drag <item> --before|--after <item> | --to-x <n> [--steps N] [--hold-ms N] [--step-ms N] [--quiet] [--trace] [--full]`.
Raw trial output: `docs/evidence/gdu7-exp{A,B,C}.txt`. Each line records the tool's own `verified` plus an independent
full `mbprobe list` 2.5 s later (the "truth" column). Bartender 7 was quit for all trials and relaunched afterwards.
Item query forms: `<bundleID>`, `<bundleID>::<substring>`, or a bare substring (id/description/title/owner); ambiguous
queries print candidates and exit 1. Control Center/clock/module items (agent-hosted) are refused.

## Result in one line
Cmd+drag works on macOS 27 with synthesized CGEvents on `.cghidEventTap`: **53/53 real drags with >=10 steps landed correctly** (20 Exp A + 23 Exp B + 10 Exp C; default 10 steps, 15 ms apart, 100 ms hold), but only if the drop point is chosen correctly (below).

## Drop-point rule (the main finding)
Aiming at an item's edge or exact center does nothing (the item snaps back). The dragged item's *center* must cross the
hovered item's midpoint: moving RIGHT drop at `hover.midX + 6`, moving LEFT at `hover.midX - 6`; the dragged item lands
on the far side of the hovered item. `after T` moving right hovers T; `before T` moving right hovers T's left neighbor;
`before T` moving left hovers T; `after T` moving left hovers T's right neighbor (`DragTarget.dropX`). Distances over
~250 px (KeepingYouAwake across 6 items) work fine.

## Verification pitfalls (matter for T07)
1. **AX lags the real bar.** The item moves on screen ~90 ms after mouse-up (screenshots), but AX frames follow only after
   ~0.4-2.0 s (median ~1.0 s); transient wrong readings (item at its old or its cursor position) occur in between.
   Closed-loop rule used: poll `scanVisible()` until two consecutive snapshots agree, but not before 2.0 s after mouse-up
   (the bead's 3 s cap was raised to 4 s), then confirm with one full `scan()`.
2. **Identity join breaks for identifier-less items.** `mbdummy` originally had no AX identifier/description; the scanner
   then joins app-side and agent-hosted elements by frame, and app-side frames lag after a move, so labels were swapped
   (DA/DB appeared reversed vs. a screenshot) and every early trial was misjudged. Fixed in the dummy (AX identifier
   `Dummy-X`, label `Dummy X`). Real-world equivalent: KeepingYouAwake has no id/description; right after a drag its fast
   scan shows an unnamed `agentHostedOnly` item at the new spot and the app item vanishes until a full scan re-joins
   it. Hence the final full-scan confirmation. T07 must not trust fast scans (or frame joins) right after a move.
3. Relation is checked by resolved keys, strict immediate adjacency.

## Experiment A: Dummy-A <-> right of Dummy-B, 10 round trips (`gdu7-expA.txt`)
20 real drags (the 21st, A1-toRight, was already satisfied and skipped): **20/20 correct**, 0 menus opened, 0 wrong slots,
0 no-movement. Params: steps 10, step 15 ms, hold 100 ms. Time to AX visibility (first poll that equals the final state):
min 0.36 s, median 1.0 s, max 2.0 s. Settle (two agreeing scans, floor 2.0 s): median 2.2 s, max 2.3 s.

## Experiment B: parameter sweep (`gdu7-expB.txt`; 3 holds x 3 step counts, 4 drags each, no-op trials excluded)
| hold ms | steps 5 | steps 10 | steps 20 |
|---|---|---|---|
| 0 | 1/3 | 3/3 | 4/4 |
| 100 | 0/2 | 4/4 | 4/4 |
| 250 | 0/2 | 4/4 | 4/4 |

(The tool printed `verified=no` for step-5 failures and the truth column agrees: item did not move.)
Step count matters: 5 steps fails (~1/7); >=10 steps is 23/23. Hold time had no measurable effect for >=10 steps.
Best/recommended: **steps 10, step delay 15 ms, hold 100 ms** (a 0 ms hold also worked but was not distinguishable;
100 ms is the conservative default). Total synthesized-drag duration ~0.3 s.

## Experiment C: KeepingYouAwake next to Dummy-A and back, 5 round trips (`gdu7-expC.txt`)
10/10 drags correct (out: `--after Dummy-A`, back: `--after com.apple.TextInputMenuAgent`), verified by full scan and
by the independent 2.5 s list; final order restored. Fast-scan polling was "unsettled" on every outbound trip (pitfall 2),
visible/confirmed by full scan (265-1730 ms). Escape was never needed.

## Experiment D: MenuBarAgent plist after a drag (`gdu7-D-before.plist`, `plistcmp.py`)
- **MenuBarAgent persists the new order itself.** After one KeepingYouAwake drag the file mtime advanced within 4 s;
  `plistcmp` shows KeepingYouAwake 570 -> 719 and every item it passed shifted by -28 (all other keys unchanged, 91 keys).
  Three timed dummy drags: plist rewritten +0.85 s, +1.43 s, and ~+4 s after mouse-up (debounced, variable). Larger value
  = further left. So no `killall MenuBarAgent` is ever needed after a drag; do not restart the agent before the file has
  changed (poll mtime) or the move may be lost.
- **Flash:** menu bar region (x 1150-1650) sampled every ~130 ms with screencapture during a drag: pixels changed exactly
  once (at mouse-up +~90 ms) with no intermediate frames; no bar blanking, unlike the ~2.5 s agent restart. (Sub-130 ms
  flicker cannot be excluded by this method; the dragged item itself follows the cursor, which is inherent.)
- **Mouse-up to visible in scans:** on screen ~0.1 s; fast scan 0.4-2.0 s (median ~1.0 s); plist 0.85-4 s.
- Cursor is saved/restored; no menu opened in any trial; `NSEvent.pressedMouseButtons != 0` refuses to start (`.userBusy`).
- Side observation: dummy values in the plist changed (A 783->747->777, B 813->777->747); extra key Dummy-C exists from earlier beads.

## Failure modes seen
- Wrong drop x (edge/center aim): silent no-op, item snaps back (not a menu).
- 5-step drags: silent no-op.
- Misleading AX labels (see pitfalls), not drag failures.
- Not observed: menu opening, wrong slot, stuck mouse.

## Conclusion
Reliability: **100% (53/53 real drags at >=10 steps: 20 Dummy, 23 sweep, 10 KeepingYouAwake; only 5-step drags fail, 1/7)**
with steps >=10 and the midpoint-crossing drop rule. Recommendation for T07: **use Cmd+drag as the primary flicker-free
reorder (closed loop: drag, wait >=2 s, full-scan confirm, retry once with the next drop point on failure), keep plist
write + `killall MenuBarAgent` only as the fallback** for failed verification or when the user is using the mouse.
Caveats: needs a quiet mouse and Accessibility, takes ~2-3 s per move incl. verification, and only reorders on-bar
third-party items (never Control Center/clock).

State at end: Bartender 7 running, MBDummy stopped, on-bar order equals `docs/evidence/gdu7-baseline.json`.
