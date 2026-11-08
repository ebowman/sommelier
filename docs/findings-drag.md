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
Step count matters: 5 steps mostly fails (1/7 succeed, 6/7 fail); >=10 steps is 23/23. Hold time had no measurable effect for >=10 steps.
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

## Command latch after the drag (sommelier-9o9.20, observed 2026-11-07)
After a Sommelier strip-session Command-drag, `CGEventSource.flagsState(.combinedSessionState)` read `0x20100000`
(Command bit `0x100000` set; `0x20000000` is the idle baseline on this machine): the synthetic drag set
`maskCommand` on its mouse events but never released the key, so the next keystrokes could be read with Command held.
Fix: the mouse-up carries no flags, and `DragMover` then posts a Command key-up (`flagsChanged`, virtual key `0x37`,
`flags = []`) on the same tap. `LivePlatform.drag` and `mbprobe drag` then call `DragModifierGuard.settle`: if
`ModifierState.isCommandLatched` (either flags state has Command), log `drag: modifier still latched; posted key-up`,
post the key-up once more, re-check, and log `drag: modifier state clear` or `drag: modifier STILL latched` (no loop).
Tests are hermetic (`DragModifierTests`: captured event sequence, fake `ModifierStateProviding`); real flags cannot be
read reliably under `swift test`. Manual check: run a strip session or `mbprobe drag`, then read
`CGEventSource.flagsState(.combinedSessionState)`; it must be `0x20000000`, and the app log must not show `STILL latched`.

## Failure modes seen
- Wrong drop x (edge/center aim): silent no-op, item snaps back (not a menu).
- 5-step drags: silent no-op.
- Misleading AX labels (see pitfalls), not drag failures.
- Not observed: menu opening, wrong slot, stuck mouse.

## Conclusion
Reliability: **100% (53/53 real drags at >=10 steps: 20 Dummy, 23 sweep, 10 KeepingYouAwake; only 5-step drags fail, 6/7)**
with steps >=10 and the midpoint-crossing drop rule. Recommendation for T07: **use Cmd+drag as the primary flicker-free
reorder (closed loop: drag, wait >=2 s, full-scan confirm, retry once with the next drop point on failure), keep plist
write + `killall MenuBarAgent` only as the fallback** for failed verification or when the user is using the mouse.
Caveats: needs a quiet mouse and Accessibility, takes ~2-3 s per move incl. verification, and only reorders on-bar
third-party items (never Control Center/clock).

State at end: Bartender 7 running, MBDummy stopped, on-bar order equals `docs/evidence/gdu7-baseline.json`.

## Intermittent adjacent-drag failures (gdu.25)

Symptom (from the gdu.9 soak): at some bar positions a Cmd+drag between two adjacent items (Dummy-A/Dummy-B) failed on both
attempts (`mbprobe drag --to-x` sweep 0/3, 1/3, 0/3, 0/3 whatever the drop offset), while the identical plan passed 20/20
elsewhere. Raw logs: scratchpad `gdu25/*.log` (per drag: source frame, hovered neighbour, drop x, per-event planned and actual
cursor, AX samples during the drag, first AX change after mouse-up, scan completeness).

### Instrumentation
`mbprobe drag --trace` now prints, per drag: source frame, the item under the drop point, drop x, whether the drop landed inside
the source's own frame, every event (planned vs. actual cursor, ms since the first event; "actual" is read right after
posting, so it trails "planned" by one event), a 20 ms AX sampler on the dragged and hovered item (`AXSelected`,
`AXFocused`, `AXPosition`), the first fast-scan poll whose frame for the moved item differs from before (ms after mouse-up) and
whether each poll / the final full scan had a complete hosted read (`hostedReadComplete`). New knobs on `drag`: `--arm-ms`
(hover on the source before mouse-down), `--pre-up-ms` (hover on the drop point before mouse-up), `--max-step-px`, `--drop-x`
(overrides the computed drop, keeps the `--before/--after` verdict). `DragMover` has the same fields (defaults 0 = unchanged).
Observations from the 50 healthy drags: no `AXSelected`/`AXFocused` change on the hovered item ever (0/50; the hover highlight is
not visible through AX), the dragged item's `AXPosition` follows the cursor from ~220 ms, first AX frame change after mouse-up
median 729 ms (min 197, max 799), and the final full scan reported an incomplete hosted read in 16/50 (the verifier already
polls until a complete read, so this only matters for the CLI's single confirm scan).

### Failing-spot search
Bartender 7 quit, MBDummy items moved only with `mbprobe move ... --force-fallback` (dummy-only order-store writes).

| spot | drags | pass |
|---|---|---|
| right of VPN Switch (mid bar, among 24 pt items) | 20 | 20 |
| right of `signal` (61 pt wide item) | 10 | 10 |
| right of Airmail2Hookmark, immediately left of Control Center/Clock (trailing block) | 10 | 10 |
| right of GateOpener, immediately left of the iStat cluster | 10 | 10 |
| **dummies at their default store values (A=783, B=813)** | 8 | **0** |

Only the last spot fails, deterministically. `mbprobe list` showed Dummy-A and Dummy-B on the bar with IDENTICAL frames
(x=784 or 791, w=32) among a run of other items with nearly identical x (786, 788, 793, 793, 798), all left of a hosted item
named `Show Hidden Menu Bar Items`. A screenshot of the bar shows the "<<" chevron (that item) and nothing drawn to its left:
**the bar is full, macOS moved those items into its own menu bar overflow area, and the agent still hosts them with frames
clipped and stacked at the left edge of the usable area.** The scanner (correctly, by AX) calls them on-bar. A drag has nothing
to grab and nothing to drop on, so it is a silent no-op; the item never moves, which the actuator reports honestly as
`notVerified`. The new-item default position (large store value = far left) is what puts a freshly started dummy there.

### Bounded experiment at the failing spot (28 real drags, <= 40)
| variant | drags | passes | first AX change |
|---|---|---|---|
| baseline: 10 steps, 15 ms, hold 100 ms, drop at the edge+4 (frames equal, so no neighbour) | 8 | 0 | none |
| (a) hover-arm 150 ms before mouse-down and 150 ms before mouse-up | 8 | 0 | none |
| (b) drop offset: hovered.midX + w/3 (x=817) / 2 px past the far edge (x=825) | 4 + 4 | 0 | none |
| (c) 20 steps, 15 ms | 4 | 1 (see note) | 492 ms (the one pass) |
| (c) 10 steps, 30 ms | - | not measured | - |
| (d) per-step distance cap (3 px) | - | not measured | - |

Note: during the (c) run the human started using the mouse and the display layout changed (the same bar suddenly had room, the
items stopped overlapping), so the single pass after three failures is not attributable to 20 steps; the follow-up (c)/(d)
runs found the order already flipped ("already satisfied") and are void, and the failing spot no longer existed. They were not
repeated because the pointer was no longer quiet (invariant: stop on mouse activity not caused by the experiment). No variant
shows any effect on the failing spot (0/24 clean drags across (a), (b), baseline), whereas the healthy spots pass 50/50 with the
existing defaults, so the cause is not drag parameters. Candidate causes ruled out by the trace: drop inside the source's own
frame (false on all 50 healthy drags; true only in the degenerate stacked case), item narrower than the step (steps are 2-3 px),
hover timing (a), drop offset (b); MenuBarAgent pid unchanged during every drag phase.

### Conclusion: reproducible trigger = the item (or the hovered neighbour) is in macOS's menu bar overflow area
Trigger: the bar is too full for the active display / front app's menus; every item ordered before the agent's
`Show Hidden Menu Bar Items` chevron is not drawn and reports clipped, stacked frames (identical x and width). Rate: 1/28 real drags (0/24 clean; the single pass, variant (c) 20 steps, coincided with a display change and is not attributable)
there vs 50/50 elsewhere. No drag parameter fixes it; the item must first get out of the overflow (hide something else, or the
order-store fallback, which does work there: it moved both dummies out of the overflow area in ~3 s each).

Fix (actuator, not DragMover defaults, which are unchanged: 10 steps, 15 ms, 100 ms hold, retry with 20 steps):
`ActuationVerifier.overflowed(_:)` flags every on-bar item before the chevron plus any fresh items with identical frame x and width.
`LiveActuator.move` checks the subject, the relation target and whatever is under the first drop point; if any is overflowed it skips
both doomed drags (saves ~14 s) and goes straight to the order-store fallback when `allowFallback`, else returns
`.failed(.mechanismFailed("... is in the menu bar overflow area (hidden by macOS because the bar is full); a drag cannot reach it"))`.
Verification is unchanged (full scan, never relaxed).

### Order-store fallback and duplicate position values
The old fallback permuted the existing values among all on-bar store keys and bailed on "duplicate position values" when two
keys shared a value (the order of tied keys is undetermined). `OrderStorePlanner` (pure, unit-tested) now assigns the SUBJECT a
unique value and leaves every other key alone when it can:
1. both neighbours exist and an integer fits strictly between them: subject = `floor((L + R) / 2)`, one key written (duplicates
   elsewhere in the store are irrelevant);
2. leftmost / rightmost participant: `R + 2` / `L - 2` (>= 1);
3. otherwise (adjacent integers, equal neighbour values, inverted values, no room at the end): the contiguous run around the slot
   is re-based: it grows one neighbour at a time until it sits between two untouched anchors with room for a spacing of >= 2 (or
   reaches an end), then its keys are spread evenly between the anchors keeping their order. Keys outside the run and `module:` keys
   are never written. One write, one respawn, then the usual full-scan verification.
The fallback is still refused when `allowFallback == false` (also with `forceFallback`). Seven planner tests plus actuator tests with
a fixture store (duplicates elsewhere -> single midpoint write; equal neighbours -> only the run is re-based; fallback disallowed).

### The overflow chevron (gdu.45, observed 2026-11-04, macOS 27.0.1, AppleLanguages en-US, en-DE, de-DE)
Dumped with a scratch AX script while MBDummy (31-60 items) filled the bar. The chevron is a hosted element of MenuBarAgent:
- `AXRole = AXButton`, no `AXSubrole`, `AXTitle = ""`, `AXIdentifier` absent, `AXHelp` absent, `AXDescription = "Show Hidden Menu Bar Items"`
  (localized text; the system language here is English, so the German string was NOT observed), `AXRoleDescription = button`.
- Frame `y=1 h=27 w=18`, while real items are `y=3 h=24`. It carries `AXImageData` (PNG of the `<<` glyph) and `AXCustomActions`, and has
  NO actions (real items have `AXPress`). It appears twice (group + button) with an identical frame.
- Structure: it is a DIRECT child of the agent's `AXWindow`. Every status item sits one level deeper, inside an `AXMenuBar` group.
- Position: it is the first drawn element; everything to its left is clipped and stacked at x ~ 557-570 (widths 32-40, a few px apart),
  e.g. 14 dummies at `x=560..568` then the chevron at `x=582`, then the first drawn item at `x=606`.
Locale-independent signal chosen (`AXElementInfo.isOverflowChevron`): AXButton + direct window child + empty identifier + empty title.
The English description is only a fallback. The chevron key stays `module:Show Hidden Menu Bar Items` under every locale (set by
`IdentityResolver` from the structural match, not from the description). The chevron can be missing from a single scan (partial
read); the scanner then flags nothing on that scan (conservative). Stacked or identical frames never flag in the
scanner; they are only the actuator's pair-local pre-drag guard (see the incident below).

#### False-positive incident and what was removed (gdu.45 review)
First version also flagged without a chevron: (2) identical x/width or > 2 pt overlap between fresh items, (3) closure of everything
left of a flagged item, (4) an overlap pass. Review: on a NORMAL bar (no chevron) 2 of 13 scans hit one coincidental identical-frame
pair far right (iStat Time + VPN Switch both at (1664,25); another time WiFi Signal + ControlCenter at (1608,24)) and the prefix
closure then flagged 19-20 of 25 items; on a full bar two DRAWN items right of the chevron (iStat CPU + ControlCenter at x=1516) were
flagged. Identical frames occur by chance, so rules 2-4 were removed from the scanner: it flags only fresh items left of a fresh
chevron of the same read; a partial scan that misses the chevron flags nothing. The identical-frame test survives only as the
actuator's local pre-drag guard (it names just that pair, as in gdu.25).

### The expanded strip (9o9.12, observed 2026-11-07)
macOS 27.0.1, full bar, 9 items behind the chevron (bd memory `system-overflow-strip-command-drag`).
- A click on MenuBarAgent's chevron (70 ms hold) expands the strip and it STAYS expanded until the chevron is clicked again; Escape does
  not close it. `OverflowProbe.expanded` is true and the app-side frames follow the strip a moment later.
- While expanded the formerly folded items are DRAWN at real frames at the left of the bar (x 270-570 on the user's bar), left of the
  chevron; nothing is stacked.
- A Command-drag inside the expanded strip reorders its items, and a Command-drag ACROSS the chevron works in both directions; macOS
  re-folds by width at once when the drawn region no longer fits (the first drawn item fell into the pile), so a move near the fold is
  only predictable while the strip is open.
- The order store (`com.apple.MenuBar.plist`) is written lazily, a few seconds after the drag.
- Stacked x carries NO order: while collapsed, stacked frames x 781/783/786 read Jump, TimeMachine, WiFi while the real order was Jump,
  WiFi, TimeMachine. Only an open strip shows the order of the pile.
- Hence the actuator's strip session (docs/architecture.md "The strip session (9o9.12)"): open, fresh re-scan, drag, close.

### The expanded strip on a narrow display (gdu.126, 2026-11-08)
644 x 1346 pt portrait display, ~30 items folded for width, Finder frontmost. AX dumps of MenuBarAgent's direct children, collapsed vs
expanded (the engine log of the same run showed three chevron clicks per folded key and "strip: did not show as expanded").
- A manual click DID expand the strip: the overflow items are drawn over the app's menu titles (Finder's), x about 135 to 445. The
  strip is an overlay on the left of the bar, it does not push the chevron anywhere.
- The chevron's frame is UNCHANGED between the states: x 453, w 18 both times. Only its description toggles: collapsed "Show Hidden Menu
  Bar Items", expanded "Hide Menu Bar Items" (the glyph turns to »).
- The pile DE-STACKS. Collapsed, the hosted elements sit stacked right behind the chevron (x 405/63, 427/41, 443/24, 443/24, 444/24,
  447/24, overlapping); expanded, the same elements have distinct real frames (x 141/51, 197/24, 226/41, 302/24, 331/24, 356/24, 381/63,
  i.e. 141 to 444, no overlaps).
- The 9o9.11 / gdu.65 rule (the agent's AXMenuBar minX LEFT of the chevron) stayed silent in both states: `stripExpanded` read none, so
  the actuator opened the strip, did not see it, did not close it (the collapse check read the same probe) and the next pass's click
  closed it again; the bar toggled under the user every 15 s.
- Fix: ONE shared `StripExpansionRule` (probe and scanner): description flips to "Hide Menu Bar Items", OR the geometric rule, OR a
  de-stacked pile (at least two non-overlapping hosted frames left of the chevron spanning at least 60 pt). Any clause says open. The
  chevron KEY is unchanged (it is derived from the English closed name; the open name is recognised as the chevron too).
- A failed open is a property of the BAR, not of a key: the engine holds every fold move for the current bar state (docs/architecture.md).
