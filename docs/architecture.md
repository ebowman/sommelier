# Sommelier architecture: actuation strategy (bead sommelier-gdu.8)

Host facts: macOS 27.0.1. All numbers come from the findings docs: positioning = `findings-positioning.md` (gdu.5),
visibility = `findings-visibility.md` (gdu.6), drag = `findings-drag.md` (gdu.7), order store = `findings-prefstore.md` (gdu.1),
identity = `findings-identity.md` (gdu.4). Quality bar from the epic: **the UI never lies**; nothing is shown as moved/hidden
until a settled full scan of the real bar agrees; failures are surfaced.

## (a) Primary mechanisms

| Action | Primary | Evidence |
|---|---|---|
| Reorder (on-bar third-party item) | Synthesized Cmd+drag via CGEvent on `.cghidEventTap`: 10 steps, 15 ms apart, 100 ms hold; drop at hovered item's `midX +/- 6 px` on the far side (`DragTarget.dropX`); wait >= 2 s; confirm with a full scan; retry once with the next drop point. No flash (bar changes once at mouse-up +90 ms); MenuBarAgent persists the new order itself, no restart. | findings-drag Exp A 20/20, B 23/23 (>=10 steps; 5-step drags succeed only 1/7, i.e. fail 6/7), C 10/10 on KeepingYouAwake, D (persist + no flash). 53/53 total. |
| Hide / show | Control Center `trackedApplications[...].isAllowed` flip (`ControlCenterTrackedAppsStore.setAllowed`) + ONE batched `killall MenuBarAgent`. ~2-3 s, 1-2 s bar flash, other items keep slots, shown items return to their previous slot. Only apps that already have a tracked entry. **Live path (gdu.39, primary when the process has the `com.apple.security.application-groups` = `group.com.apple.controlcenter` entitlement, `AppGroupEntitlement`):** `ControlCenterTrackedAppsStore.setAllowedBatchLive` (CFPreferences set + synchronize, read back through CFPreferences), then `LiveActuator` polls full scans every 0.5 s until the first COMPLETE hosted read decides (an unsatisfied complete read gets one more complete read before giving up; hard ceiling 8 scans / 20 s). No respawn, no flash. Measured 2026-11-04 (MBDummy, Bartender quit, ad-hoc signed): write to verified 0.61-5.15 s over 40 ops (min 609 ms, median ~2.0 s, max 5146 ms; scan-bound, implementer soak 40/40 live, MenuBarAgent pid unchanged; the reviewer's run was 4/6 live under the old 6 s wall bound because of incomplete-read streaks of 2-3 s scans, hence the scan-count bound; fallback should now occur only when no complete read arrives within the ceiling); engine `apply` 5.6-6.5 s wall incl. ~4.5 s observe, actuation 0.63-0.71 s. Fallback = the respawn path above (unentitled binary: ~2.9 s and ~8.4 s measured; also after a live write throws or two complete reads disagree, or no complete read arrives within the ceiling). Developer ID/notarized: see findings-live-trigger section 8. The file-read fallback in `setAllowedBatchLive` (when CFPreferences returns nil) and the respawn fallback's file write can push a lagging on-disk blob into cfprefsd; low probability, same as the pre-existing respawn path. **Scanner detection of a live hide has three evidence kinds (of7):** (1) hosted-by-name: an item with an AX identifier (or description) that was seen hosted and is absent from a COMPLETE hosted read is `notHosted` (gdu.38); (2) parked frame (x -1..3, y ~1188), the post-respawn state; (3) write-time hosted-ELEMENT evidence for identifier-less items (Tot, Yoink, Moom; their hosted and app-side elements share no name, only an unreliable frame join): `LiveActuator` takes the attributed hosted tree of the full scan it already made before the write (`MenuBarSnapshot.hostedLayout`; if that read is incomplete: complete scans retried for up to 4 s, then the scanner's last complete tree if at most 10 s old; the trace says which baseline was used), writes, and probes complete hosted reads at 0.3/0.8/1.5/2.5/4/6 s plus the poll's own complete scans. Verified iff the post-write tree equals the pre-write tree minus exactly the unit's joined elements, in order (`HostedEvidence.removedExactly`: same identifiers/descriptions; widths compared only for identifier-less elements, because named readouts change width on their own; modules must still be present), and no other app-side item left the bar. A mere count match is NOT evidence (another element vanishing while one appears has the same count). Only pure-hide batches; a batch that also shows items keeps the complete-read poll alone. Evidence records the owner in `ScanState.assumedHidden` (pid, bundle id, Control Center tracked key, time, hosted count after, item count; persisted in `scan-cache.json`, so `mbprobe list` sees it). `MenuBarScanner` then reports that owner's identifier-less, on-bar-framed items `isOnMenuBar = false`, `hidden = assumedNotHosted`. Cleared by: a live/respawn SHOW by us (actuator and `ItemActivator` clear it at write time), a respawn, the owner quitting, a different bundle id on that pid (reuse guard), Control Center `isAllowed` reading true again (CFPreferences readback, at most every 60 s: someone else showed it), a contradicting COMPLETE read (a hosted element of the same width overlapping the candidate while the hosted count is back to >= count-after + items), or a 2 h hard safety expiry (logged). There is no short timer: while the owner runs and nothing contradicts, the record stands. Asymmetry: the flag is ONLY set by our own successful write plus element evidence, never inferred from frames or absence alone, so an untouched bar cannot produce a false hidden; a wrongly cleared flag merely restores the old behaviour (reported on-bar, respawn fallback). `ItemActivator` records the flag after its re-hide write when the hosted tree is again exactly the pre-reveal tree, and the activator shares the engine's `LivePlatform` (one scanner, one `ScanState`), so the engine's next pass plans nothing; while a transient reveal hold is active the engine plans no actions and records no new items at all (a revealed element may appear as an unknown heuristic item that must never be dragged). The flag is keyed by pid (the unit is the owner; identifier-less items' own keys are frame-based and move). | findings-visibility A2/A4/A6 (applies only after agent restart; no live reload A1/A3/A5); A7/A8 (hand-made entries are not honored); conclusion. |

Legacy per-app `NSStatusItem Preferred Position` / `Visible` writes are NOT mechanisms on this OS (findings-positioning A/B;
findings-visibility B1-B5).

## (b) Fallbacks

* **Reorder fallback: order-store edit + agent restart.** `MenuBarOrderStore` writes
  `TrailingItemPreferredPositions[status:<ownerKey>::<autosave>]` (bigger = further left; only relative order matters; fresh keys are
  accepted; never `module:`), then `killall MenuBarAgent` (`MenuBarAgentControl.restart`). Used when (1) a drag failed verification
  twice (the initial try plus the one retry), (2) the mouse is busy for the whole wait window and the user has asked for the change
  anyway (UI may offer "apply now with flash"), or (3) a plan contains many moves (rule of thumb: >= 4 moves, or a move of a parked
  item, which cannot be dragged) so one restart beats N sequential 2-3 s drags. Evidence: findings-positioning C1-C4, D, and
  restart cost C6 (2.4-2.7 s stable, 4.5-5.8 s in 5 runs; two runs hit the 10 s poll timeout, one completing ~5 s later, i.e. ~15 s) and visibility A2 ("~1-12 s").
  The restart must wait for the order file to be quiescent (poll mtime; drag Exp D: the agent rewrites it 0.85-4 s after mouse-up) or a
  pending agent write can clobber ours.
  **Value rule (gdu.25, `OrderStorePlanner`):** the fallback never permutes values among keys and never bails on duplicates. The subject
  gets one unique value strictly between its new neighbours (`floor((L+R)/2)`; `R+2` / `L-2` at an end); when no integer fits (adjacent
  integers, equal neighbour values, inverted values) the smallest contiguous run around the slot is re-based between two untouched anchors
  (spacing >= 2, order kept, never a key outside the run, never `module:`). One write, one respawn, full-scan verification. Refused
  when the engine config has `allowFallback == false`.
* **Hide with no tracked entry:** no mechanism exists. `Capability.canHide == false` with a reason; the UI greys the control and
  offers "Open System Settings > Menu Bar". Not silently dropped: follow-up bead **sommelier-gdu.24** investigates whether the system
  creates an entry on first launch / after an agent restart and whether we can then hide the item.
* **Hide for Apple apps / modules:** only through System Settings (store refuses `com.apple.*` and `module:`).
* **Show-in-place without restart:** none. AXPress on a parked item opens its UI (see (d)) but does not un-hide it.

## (c) Closed-loop contract

Every `MenuBarActuator` call follows: **precheck -> act -> settle -> verify -> typed result**.

1. **Precheck (no side effects).** Key absent from the latest snapshot -> `.failed(.notFound)`. `Capability` says no ->
   `.failed(.unsupportedItem(reason))`. No Accessibility -> `.permissionDenied`. Drags only: `NSEvent.pressedMouseButtons != 0` ->
   re-check for up to 2 s, then `.failed(.userBusy)`.
2. **Act.** One mechanism (a), or the fallback (b). All actuations serialize through one actor; drags are strictly sequential.
   `DragMover` must guarantee a mouseUp is posted even when event creation fails after mouseDown (gdu.7 review). After a drag, check
   for an opened `AXMenu` on the item; if present post Escape and return/count `.mechanismFailed("menu opened")`.
   Before any actuation, if Bartender 7 (`com.surteesstudios.Bartender`) is running, return `.failed(.conflictingManager("Bartender 7 is running"), nil)`.
3. **Settle** (`SettleDetector`, gdu.9): poll until two consecutive agreeing scans (same keys, same order, frames within 1 pt). Fast scan
   (`scanVisible`, sub-second) is for polling only; the **final verdict always uses a full scan** (fast scans mislabel identifier-less
   items right after a move: findings-drag pitfall 2). Floors/caps: after a drag wait >= 2.0 s after mouse-up (AX lags 0.4-2.0 s,
   median 1.0 s) with a ~4 s cap; after an agent restart wait until the hosted count recovers (budget 15 s; typical 2.5-3 s), then the same two-scan rule.
   **Stale items never count as verified**: if the moved/hidden item (or its neighbor in a relation) has `stale == true`, keep waiting for a
   fresh read or fall back to a full scan; still stale at the cap -> `.timeout` (gdu.23 review).
4. **Verify (predicate on the final full scan, resolved to keys by `IdentityResolver`):**
   * move: strict immediate adjacency per `Relation` (`DragTarget.holds`); `.leftmost`/`.rightmost` = first/last non-module on-bar item. NOTE: the existing `DragTarget.holds` / `DragRelation` only support string-keyed `before`/`after`/`toX`, not `.leftmost`/`.rightmost` and not `ItemKey`; **gdu.9 must extend `DragRelation` to ItemKey-keyed `before`/`after`/`leftmost`/`rightmost` and implement verification for all four**;
   * hide: item present and `isOnMenuBar == false` (parked); show: on bar;
   * batch: every key in the batch satisfies its predicate AND no non-batch item changed on-bar state;
   * a verdict that depends on a `heuristic` key (or an `inferred` one in a stale-prone owner) cannot be `.verified` unless the item is
     also confirmed by a non-frame attribute (AXIdentifier) in the full scan; otherwise `.notVerified`.
5. **Result.** `.verified(snapshot)` or `.failed(error, lastSnapshot)`. Mismatch -> `.notVerified(expected:, observed:)`; no convergence ->
   `.timeout`; anything else (event creation failure, plist write error) -> `.mechanismFailed(String)`.

**Retry policy.** Drag: attempt 1 with standard drop point; on `.notVerified` retry once with the drop point shifted (+/-6 px more, or 20
steps); second failure -> fallback (order store + restart, if allowed by the caller) else `.failed`. Never retry after `.userBusy`,
`.permissionDenied`, `.unsupportedItem`, `.notFound`. **Overflow guard (gdu.25):** items macOS has pushed into its menu bar overflow (ordered before the agent's `Show Hidden Menu Bar Items`
chevron, or stacked with identical frame x/width) are reported on-bar but not drawn; drags there fail 27/28 (the one pass was confounded by a display change; 50/50 elsewhere, findings-drag
"Intermittent adjacent-drag failures"). If the subject, the target or the item under the drop point is overflowed the drags are skipped:
straight to the fallback when allowed, else `.failed(.mechanismFailed("... overflow area ..."))`. Drag defaults are unchanged (10 steps, 15 ms, 100 ms hold;
retry 20 steps), no parameter variant helped. Restart-based actions: one retry of the restart if the verifying scan still shows the
old state AND the plist write is confirmed to have landed; second failure -> `.failed`.

**Live hide/show path found (gdu.36, `docs/findings-live-trigger.md`):** writing `trackedApplications` through cfprefsd under `group.com.apple.controlcenter` (needs the app-group entitlement) hides/shows with no MenuBarAgent respawn; respawn stays the fallback. Verified in gdu.40 (`docs/findings-live-trigger.md` section 8): a Developer ID + hardened runtime + notarized binary with that entitlement gets the live path on the dev machine (macOS 27.0.1); not proven for an app bundle on a fresh Mac or macOS 26, so the respawn fallback stays.

**Batching.** All hide/show changes in a plan are collected into ONE `isAllowed` write + one restart (`applyHiddenBatch`); fallback reorders
join the same restart. Drags are never batched with each other (sequential, each verified) and run **before** any restart in the same plan
(a restart blanks the bar for 1-2 s). Restart happens after the agent-store file is quiet. A batch is all-or-nothing at the write
stage (validate every key first, back up the plist in memory), verification is per-key.

## (d) Identity model and the three sections

`ItemKey` (`ItemKey.swift`): `.status(ownerKey, autosaveName)` and `.module(name)` are byte-identical to `TrailingItemPreferredPositions`
keys; `.heuristic(bundleID, fingerprint, ordinal)` is synthesized. `ownerKey` is the bundle id for installed apps and the executable name
otherwise (findings-identity; the dev Sommelier build and MBDummy therefore key as their executable name).
`KeyConfidence`: **exact** (store key + AXIdentifier corroboration), **inferred** (real store key, pairing by order or single candidate),
**heuristic** (attribute fingerprint, not a store key). Rules for the UI:

* exact: full controls, "verified" claims allowed.
* inferred: movement is allowed (drags use the live item's frame, not the key), but any claim about a persisted position is made only after a
  full scan; fallback (order-store edit) is allowed only for exact keys or inferred keys confirmed by a post-hoc scan, because writing
  the wrong autosave name would silently move a different item.
* heuristic: drag allowed (frame-based) with greyed "unverified identity" state; never written to the store; hide only if a tracked entry
  is known; never persisted as a user layout (session only).
* stale items: shown, greyed, no actions, never counted as verified.

**Sections** (left to right on screen: visible | hidden | always-hidden is a UI model; the OS has only "on bar" and "parked"):

* **Visible**: `isAllowed == true`, on the bar. Order = drag / order store. Right boundary: Control Center + clock (cannot be passed).
* **Hidden ("the rest")**: Sommelier's own concept for items shown only on demand. OS-level they are parked via `isAllowed=0`, exactly like always-hidden;
  they differ only in panel exposure and in inline reveal (reveal shows Hidden only; option-reveal shows both). Temporary show has two implementations:
  1. **Inline reveal** = batch `isAllowed=1` + restart; re-hide = batch `isAllowed=0` + restart. Each costs ~2-3 s and a flash, so it is
     only used when the user wants the items in the real menu bar.
  2. **Overflow panel (preferred for "show the rest temporarily")**: items stay parked (`isAllowed=0`); the panel lists them from the scan
     and activates one with `AXUIElementPerformAction(kAXPressAction)` on the parked item. The real UI opens but anchored at an unrelated place
     (Yoink at the left screen edge, Tot at x~710); AX can return -25204 although the menu opened, so success is judged by observing the item's
     children; Escape via CGEvent dismisses. Evidence: findings-visibility C. Live images need Screen Recording (f).
* **Always-hidden ("never show")**: `isAllowed=0` and never offered by the panel's quick row; shown only in the settings list. Mechanically
  identical to Hidden: parked via Control Center; never revealed by plain inline reveal, only by option-reveal. The distinction between "hidden" (offered in the panel) and "always-hidden"
  (not offered) is Sommelier's own layout state, persisted by us.

So: *Visible* = allowed. *Hidden* and *Always-hidden* both = parked by `isAllowed=0` (one restart batch), differing only in panel
exposure. An item in the Hidden section that has no tracked entry cannot be parked and is shown disabled (see (e)).

### Layout model

`Layout` (`Sources/SommelierCore/Layout.swift`) is the persisted desired state, free of AX/UI types.
- File: `~/Library/Application Support/Sommelier/layout.json` (`FileLayoutStore.defaultURL()`); keys are stored as their
  `ItemKey.description` strings (`status:owner::name`, `module:Name`, `heuristic:...`).
- Sections: `visible`, `hidden`, `alwaysHidden` (ordered); a key lives in at most one section. Mutators (`move`, `remove`,
  `append`, `reorder`) enforce this; `validated()` dedups keeping the first occurrence (visible, hidden, alwaysHidden).
- Import order: `LayoutBuilder` writes `visible` in the observed left-to-right order (frame minX; ties keep the scanner's discovery
  order, i.e. the hosted tree's child order), modules included, without `append`'s
  trailing-block insertion rule.
- Hide unit (`HideUnit`, `ItemKey.hideUnit`, `hideUnits(_:)` in `ItemKey.swift`): Control Center hides per app, so the unit is the
  `ownerKey` for status items, `module:<Name>` for each module (independent), the bundle id for heuristic keys. A unit is hidden
  only if ALL its items are in `hidden`/`alwaysHidden` (a `hidden`+`alwaysHidden` split is fine). `Layout.normalizedHideUnits()`
  moves the hidden-section keys of a unit that also has a `visible` key to `visible` (before the trailing system block, original
  order); `validated()` applies it after `dedup()`, `validatedReportingNormalization()` also returns the moved keys (no hidden state
  on `Layout`), and `Layout.decode` adds a warning, so the load path reports it once (mbprobe prints it, the engine `NSLog`s it).
  `Layout.move(key, to:index:)` moves the WHOLE unit (key at the index, siblings right after it) and returns every moved key, `key`
  first (`mbprobe layout move` prints "also moved: ..."). `append`/`reorder` place only the given key (builders, in-section order).
- `newItemPolicy`: `visibleAtEnd` (default) or `hidden`, applied by the planner to keys not yet in the layout.
- Keys of apps that are not running stay in the file untouched (absent is not unknown).
- Schema: `schemaVersion` (currently 1). Lenient decode (missing fields default; duplicates dropped with warnings via
  `Layout.decode`). Lower versions migrate in memory on load (no rewrite); higher throws `unsupportedSchema`.
- Writes are atomic: temp file `layout.json.tmp-<uuid>` in the same directory, then `rename(2)`.
- A corrupt file (bad JSON or unparsable key) is copied to `layout.json.bak` and `load()` throws `LayoutError.corrupt`;
  a missing file loads as `Layout.empty`.
- Dev tool: `mbprobe layout show|init-from-current|move|remove [--file PATH]`.

### Reconciler

`Reconciler.plan(observed:layout:capabilities:showHiddenSection:)` (`Reconciler.swift`) is pure: observed `ObservedOrder`
(on-bar left to right + parked; stale and width<=1 items excluded) and a `Layout` in, a `Plan` out. The engine loops observe -> plan -> act -> verify.
- Phases: `.membership` returns only hides then shows (one batch; MenuBarAgent picks where a shown item lands, so order cannot
  be planned yet); `.order` returns only moves; `.converged` returns nothing. Expect at most 3 plans.
- Anchors never move: `canMove == false` items and items that should be hidden but have `canHide == false` (reported in `skipped`).
  Anchors are part of the target: the target is the layout's full on-bar order including anchors, so movable items are arranged
  around them (an anchor the layout does not place keeps its observed slot). Convergence means the observed order equals `desiredOnBar`
  with anchors included. If the anchors' relative order on the bar differs from the layout's, that part is unreachable: each offending
  anchor goes into `skipped` ("immovable item is out of layout order"; the engine shows `.unsupported`) and the rest is planned with
  every anchor in its observed slot.
- Trailing system block: the maximal suffix of the bar made only of anchors (Control Center modules, clock) is unreachable for third-party
  items on macOS 26+. A movable key the layout places right of its first item goes into `skipped` ("cannot be placed right of the system
  items (<anchor>)") and is relocated in the target to the last slot before the block (relative order kept), so no drag ever has an anchor
  as subject or a destination in the block (asserted after `moves`). Non-trailing anchors (e.g. `module:WiFi` mid-bar) are unaffected.
  Correspondingly `Layout.move(_, to: .visible, index: nil)` inserts before the trailing run of `.module` keys instead of appending
  (`Layout.trailingSystemBlock`); an explicit index is literal and `mbprobe layout move` warns when it lands in the block.
- Hide units: membership is decided per unit before any hide/show is computed. A unit is wanted-hidden only if all its observed
  layout-listed keys are hidden-listed and the hidden section is not being revealed with `showHiddenSection`; a unit with any `alwaysHidden` key stays hidden even while revealing (its `hidden` keys get a "kept hidden together with <key>: an always-hidden item keeps its app hidden" skip, and `OverflowEntry.pinnedHidden` marks them in the panel); otherwise it is wanted
  on the bar and each hidden-listed key goes into `skipped` ("hidden together with <ownerKey>: all items of an app hide or show at
  once"). `hides`/`shows` cover every observed key of the unit, so the actuator batch is complete and never conflicts. Unknown items
  of a listed unit follow the unit; a wholly unknown unit follows `newItemPolicy` only if one of its items is on the bar. If a unit
  must hide but one item cannot (`canHide == false`), none of it is hidden (all anchored, reported in `skipped`). The overflow panel
  (`OverflowEntry.unit/unitSize`) keeps a unit adjacent, with a divider between units and a count badge plus "Hidden together" tooltip.
- Unknown keys (not in the layout) follow `newItemPolicy` and are returned in `newItems` (the planner never mutates the layout);
  unknown parked keys are never shown. Layout keys not observed are listed in `absent` and ignored.
- Minimality: anchors are always kept; per gap between anchors, a longest increasing subsequence of movables stays put; moves == misplaced items. Moves are emitted
  left to right in target order, preferring `.after(left neighbour)`, then `.before(right)`, and `.leftmost`/`.rightmost` only as a last resort.
- `PlanSimulator.apply` replays actions on an `ObservedOrder` (show slot injectable); `ReconcilerRandomTests` uses it for seeded convergence checks.
- Dev tool: `mbprobe plan [--show-hidden] [--file PATH] [--json]` prints the plan and executes nothing.

### Observer (`AgreedScanObserver`, gdu.46)

`observe()` is strict (settled or throws `noAgreement`); `observeDetailed(progress:)` is what the engine uses.
- **Agreement**: two consecutive full scans must show the same (1) ORDER of on-bar identified keys (AX identifier present, not a heuristic key, owner not self-positioning (`LiveActuator.Config.selfPositioningOwners`, iStat), not in `volatileKeys`), (2) PRESENCE of every other on-bar key (identifier-less items and iStat count for presence, not order), (3) set of parked keys and set of stale parked keys. A stale item ON the bar blocks agreement. Width <= 1 items are ignored.
- **Exempt keys** (`volatileKeys`): `module:WiFi` and `module:com.apple.menuextra.focusmode` are ignored entirely; the agent's hosted tree drops and re-adds these leftmost modules between reads with no read error (findings-restart-collateral.md, "Scan agreement noise, gdu.46").
- **Duplicates**: a key never appears twice in a result (first by position, a fresh copy beats a stale one; logged with each copy's x, size, stale flag, source and identifier).
- **Exhaustion** (`maxScans` 6 / `deadline` 15 s): the latest COMPLETE read (`MenuBarSnapshot.hostedReadComplete != false`), preferring one with no on-bar stale item, is returned with `settled == false`; with no complete read the error is thrown as before (`noAgreement`, or `empty`).
- Every scan logs `observe scan N: hostedComplete=... onBarStale=... agree=...` into the app log (`engine: observer: ...`).
- First-launch layout creation (`AppModel.startIfReady`) writes a layout only from a settled read; an unsettled one leaves the layout empty (the engine then adopts new items visible at the end) and logs it.

### LayoutEngine

`LayoutEngine` (actor, `LayoutEngine.swift`) runs the observe -> plan -> act -> verify loop; `EngineState` (`@MainActor @Observable`) is the only thing the UI binds to.

- **Pass**: (1) `observeDetailed()` (two agreeing full scans, see "Observer" below; observation moves nothing, so it runs even while the user is busy); (2) if the mouse is down (`busy`), wait up to 3 s polling every 0.1 s, else skip and retry once (after a wait the observation is repeated); (3) plan with failed keys forced to `canMove = canHide = false` (they become anchors); (4) persist `newItems` into the layout (once per pass) per `newItemPolicy`; (5) act; (6) publish.
- **Two phases**: *membership* is one `applyHiddenBatch` (one agent restart, never called with an empty batch), then re-observe and re-plan; *order* is one `move` at a time, re-planning from the verified snapshot after each. Both continue in the same pass when the post-membership plan is `.order`. At most `maxActionsPerPass` (50) actuator calls per pass; 3 consecutive failures stop the pass (`lastError`, no chaining); a membership batch that reports failure/drift ends the pass with `lastError = .batchDrift` (cleared only by `clearFailures`/`setLayout`) and never chains into drags; at most 2 chained passes. `mbprobe apply` runs the actuator drag-only unless `--allow-fallback`.
- **Observed truth only**: `EngineState.observed` is set solely from an actuator-returned snapshot or a fresh observe, never from the plan. `perItem` is `.inPlace/.pending/.moving/.failed/.unsupported`; `unsupported` (capability skips) does not block `isConverged`, `failed` does.
- **Suppression**: a key whose actuation failed stays suppressed until `setLayout`, `clearFailures()`, or its app disappears from the bar. This stops the 10 s poll from re-running a failing agent restart forever. `userBusy` is not a failure and is not suppressed.
- **Fatal errors**: no Accessibility permission or a competing manager (Bartender) sets `lastError`, makes no actuator call and stops the engine until `clearFailures()`.
- **Unsettled observations (gdu.46)**: when the scans never agree but a complete read exists, the pass publishes it (`EngineState.observed`, `observationSettled = false`, `lastError` cleared only when it was an observe error (permission errors still surface); status line "Observing (unsettled)"), logs `observation unsettled; not actuating`, plans nothing, finishes with `PassReport.Outcome.unsettled` and schedules the next pass (`minPassInterval`). Only a settled observation is ever planned on or acted on. The unsettled pass still increments `passSequence` (it must stay aligned with `passesStarted`), so `ArrangeTracker` ignores unsettled states: it suppresses every tracked key's engine status (capsules stay at the pending spinner), judges nothing and pauses its 90 s clock; judging resumes at the next settled state with `passSequence > dropSequence`. The first non-empty scan of a pass is also published at once as a provisional observation when nothing has been observed yet (log `first observation published (provisional, unsettled)`), so the Arrange window has a bar within a scan or two instead of after agreement.
- **Pass latency (gdu.46)**: `setLayout`/`setShowHiddenSection` call `requestReconcile(supersede: true)`: an observation in progress is cancelled between scans (`ObserveError.superseded`, outcome `.superseded`, the pass ends and the next starts at once; a plain trigger/poll never cancels it, or a slow observation would starve forever). A pass that is already actuating cannot be cancelled mid-drag, but it re-plans from the CURRENT layout after every action, so the new layout is acted on at the next re-plan (log `picked up by the running pass at its next re-plan, N ms`). Logs: `pass started N ms after <reason>` for every request, `pass delayed: <reason> N ms` for any wait over 2 s (previous pass running, user busy). Measured: idle 0 ms; superseding an observation ~0.5 s; during a drag 1.4-5 s (the rest of that drag).
- **Scheduling**: `requestReconcile()` sets a pending flag; concurrent triggers coalesce into one follow-up pass; pass starts are at least 0.5 s apart. `reconcileOnce()` runs exactly one pass (`mbprobe apply`, tests).
- **Triggers** (`EngineTriggers`, AppKit): app launch/terminate (debounced 1 s) and a 10 s poll that fires only when a fast scan differs from `state.observed`. The live `busy` closure is `NSEvent.pressedMouseButtons != 0`.
- **UI binds to**: `observed`, `layout`, `perItem`, `inFlight`, `lastError`, `isConverged`, `lastPassAt`, `passCount`; it changes the bar only via `setLayout` / `setShowHiddenSection`.

## (e) What cannot be done, and how the UI shows it

| Limit | Evidence | UI |
|---|---|---|
| Module items (Wi-Fi, Battery, clock, Control Center, Siri): cannot be dragged, cannot be placed right of Control Center/clock; hidden only in System Settings > Menu Bar | findings-positioning C3 (placement limit, measured); no-drag is a self-imposed rule (`ItemResolver.protected`, mbprobe refuses), untested by design since we never drag Control Center/clock; store refuses `module:` (self-imposed guard) | lock icon; `Capability.canMove=false, canHide=false`, reason tooltip, "Open Settings" link |
| Third-party item cannot go right of Control Center | positioning C3 | drop target clamps; `.rightmost` means just left of Control Center |
| App without a Control Center tracked entry cannot be hidden | visibility A7/A8 | `canHide=false` + reason; bead gdu.24 |
| Apple (`com.apple.*`) apps cannot be hidden by us | store guard | same |
| Parked item cannot be dragged | drag findings (on-bar only) | reorder of a parked item uses the fallback or is disabled until shown |
| Stale / heuristic identity | gdu.23, gdu.4 | greyed with "unverified" badge, actions disabled until a fresh full scan |
| Show/hide is not instant | visibility conclusion | progress state ("applying, ~3 s") then result from the verified snapshot, never optimistic |
| Failed action | contract (c) | item snaps back in the UI, inline error with the typed `ActuationError` |

The contract carries per-item `Capability { canMove, canHide, reason }` (`MenuBarActuator.swift`, `CapabilityProvider`, `CapabilityRules`).
Findings do not conflict dummy-vs-third-party for drag (KeepingYouAwake 10/10); hide was only measured on the dummy (A) and via AXPress
on third-party (C), so third-party hide is the one capability to confirm in the gdu.9 soak (hide/show one tracked third-party item,
restore afterwards).

## (f) Permissions and distribution

* **Accessibility**: required (scanning, AXPress, and CGEvent synthesis for drags).
* **Screen Recording**: only for live images of items in the overflow panel (T17). Everything else works without it.
* **Not sandboxed**: we write other apps' group-container plists (`com.apple.MenuBar`, `group.com.apple.controlcenter`) and run `killall`
  on MenuBarAgent. Distribution: Developer ID, not the Mac App Store.
* Files: `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist` (read by plain
  `PropertyListSerialization`; not visible through CFPreferences) and `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`.
  Atomic writes, keep mode, in-memory backup before every write.

## Risks

* **Restart recovery** is typically 2-3 s but up to ~12 s (visibility A2) and ~15 s (positioning C6: a run hit the 10 s timeout and completed ~5 s later) was observed; the hosted AX count is noisy
  (133-151), so recovery uses a 90% threshold and a cap, then the normal settle.
* **iStat Menus AX slowness**: reads time out, cached values served as `stale`; stale never verifies (gdu.23).
* **Fast scan mislabels identifier-less items right after a move** (findings-drag pitfall 2): final verdict = full scan.
* **Order store contains stale duplicate keys** (`FloTile`/`ie.boboco.FloTile`, old iStat translocated set, inert test keys from gdu.4):
  writes target only the key the resolver chose; never "clean up" without user request.
* **Bartender must not run concurrently**: it parks and moves items itself and will fight both mechanisms; the app should detect it
  (`com.surteesstudios.Bartender`) and refuse to actuate with a clear message.
* **Dev build owner key is its executable name** (not the bundle id) because it runs outside `/Applications`; keys differ between dev and
  installed builds.
* **User's mouse**: drag needs a quiet mouse; restart-based fallback exists, but gives a flash.
* **Agent restarts re-base stored positions** (docs/findings-restart-collateral.md): the order store values of ALL owners (modules too) are rewritten when the item set changes, which can re-sort items of other apps (iStat, interleaved with others, ended up left of Wi-Fi). `applyHiddenBatch` snapshots the store before the restart and, if the post-restart relative order of the common items drifted, writes the old values back and restarts once more. Duplicate owner-key forms (iStat bundle vs executable) were tested and are not the cause, so they are not touched.
* **Do not `killall ControlCenter`** (Elgato Control Center shares the process name); only `MenuBarAgent` is restarted.
* Spacing (NSStatusItemSpacing/SelectionPadding) is out of scope of this document; it is handled by bead sommelier-gdu.20.
* The OS-26 behavior is assumed identical; unverified.

## Follow-up beads

* **sommelier-gdu.24**: investigate hiding apps with no Control Center tracked entry.
* Not wholly infeasible: nothing else; every required capability (reorder, hide/show, panel activation) has a working mechanism.
* `mbprobe --fake` plumbing was skipped (not trivial: mbprobe has no actuator subcommands yet; gdu.9 adds `move/hide/show`).

## Code contract

`Sources/SommelierCore/MenuBarActuator.swift`: `MenuBarActuator`, `Relation`, `ActuationResult`, `ActuationError`, `Capability`,
`CapabilityProvider`, `CapabilityRules` (`ActuationError.conflictingManager(String)` for a running competing manager). `Sources/SommelierCore/FakeActuator.swift`: scriptable in-memory implementation.
`Tests/SommelierCoreTests/ActuatorTests.swift`.

## App shell
- `AppDelegate` (main actor) creates `AppModel`, `StatusItemController` (NSStatusItem, autosave "Sommelier") and the
  settings/onboarding windows. The main actor only renders `EngineState` and sends commands to the engine.
- `LayoutEngine` (actor) does all scanning, planning and dragging off the main thread; `EngineFactory.makeLive` wires it
  (drag-only: `allowFallback = false`), shared with `mbprobe apply`.
- Startup: refresh permissions -> if Accessibility missing show onboarding and stop -> if Bartender runs, show "paused" and
  poll every 5 s -> build engine, `start()` -> no layout file: initialize from one agreed scan (on bar visible, parked hidden)
  -> `requestReconcile()` once -> `EngineTriggers.start()`.
- Left click toggles the hidden section; right click shows the menu (rebuilt per open). Our own item is never scanned.
- Bartender launch stops triggers and pauses; its termination resumes. `permissionDenied` stops triggers and shows onboarding;
  re-grant calls `clearFailures()` and restarts.

### System overflow (gdu.45)
When the bar is full macOS (MenuBarAgent) hosts a chevron ("<<") and pushes the leftmost items behind it. They stay in the
hosted tree, so `isOnMenuBar` keeps meaning "on the bar per the agent", but they are not drawn and a drag on them is a no-op.
- The scanner sets `MenuBarItem.systemOverflow` (`SystemOverflow.mark`) for exactly one case: a fresh on-bar item whose frame
  lies left of a FRESH chevron (`isOverflowChevron`, found structurally, see docs/findings-drag.md) in the same read. No
  chevron, or a stale one, flags nothing (conservative). Stacked or identical frames never feed the flag. They are only a local
  pre-drag guard in `ActuationVerifier.overflowed`, which also reads the flag. `ObservedOrder.systemOverflow` /
  `overflowChevron`, `ItemInfo.systemOverflow` and `ItemStatus.notFitting` carry it to the planner and UI.
- Rule: Sommelier orders the drawn bar; macOS decides what overflows (it depends on total width), so a layout's order across the
  overflow boundary is not a request Sommelier can act on. `Reconciler.plan` drops the overflowed keys and the chevron from
  `desired` and `base` before the order planning: no drawn key is ever anchored or reported because of them, whatever the layout
  lists (unknown, pulled-in, normalized or churned), and the planner never emits a "does not fit" skip. No move has an
  overflowed item or the chevron as subject or relation target, and none drops left of the chevron (a `.leftmost` drop becomes
  `.before(first drawn item)`); `overflowViolations` asserts this. Membership is unchanged (an overflowed item may still be
  hidden, which frees room). Overflowed items show as `ItemStatus.notFitting` and as `.notFitting` panel entries, never as
  unsupported. To bring one into view, hide something else or use the future "hide what does not fit" action.
- Policy: display-only. The overflow panel lists these items after the hidden ones (`OverflowEntry.kind == .notFitting`, divider,
  warning marker, tooltip "Does not fit; macOS moved it into its overflow"). Nothing is auto-hidden. The Arrange window's
  "Hide what does not fit…" button (gdu.19, enabled only when something overflows, confirmation sheet listing the units) calls
  `Layout.hideNotFitting(_:)` to move that tail to `hidden`; overflowed items that cannot be hidden (Apple, untracked apps) are
  listed as staying.

## Arrange window (gdu.19)
`ArrangeView`/`ArrangeWindowController` (app target, single instance, frame autosave "Arrange") render `ArrangeViewModel`
(`@MainActor @Observable`), which feeds the pure `ArrangeModel.swift` in SommelierCore (`ArrangeSections.make`, `.badge`,
`.placementMatches`, `ArrangeDrop.drop/step/hideNotFitting/adopt`; unit-tested without AppKit).
- Truthfulness rules. (1) The Visible strip is the OBSERVED bar (`EngineState.observed.onBar`, system modules as greyed,
  non-draggable anchors) and is never reordered optimistically. A requested move shows a dashed ghost "⟳" at the target slot
  (the layout neighbours decide the slot), and the real capsule keeps its observed place with "⟳" until BOTH a pass has finished
  after the drop AND `placementMatches` (the observed drawn order equals the layout order, or the item is off the bar for the
  hidden sections) AND the engine status is in place; only then does it show "✓". The view model remembers the moved keys
  (`ArrangeTracker`, pure, in `ArrangeModel.swift`; siblings of the hide unit included). A drop is judged only by a pass that STARTED
  after it (`EngineState.passesStarted` at drop time vs `passSequence`, re-stamped when the engine publishes the new layout); older
  statuses are suppressed and shown as "⟳", so an old failure never appears on a new drop. After 90 s without a match the capsule shows
  the timeout "⚠", cleared by a later match. Without a trustworthy observation (none yet, or `lastError` is an observe failure) the
  Visible strip shows "No observation yet - ..." and no capsules, and drops that touch Visible are refused. Capabilities come only from
  `ItemInfo`; a key without one is unknown and allowed (the engine decides). (2) A badge is "✓" only
  when the engine status says in place; failed -> "⚠" with the error text as tooltip, `.unsupported` -> "⊘" with the reason,
  `.notFitting` -> the does-not-fit marker; items whose app is not running carry no badge and sit in a collapsed "Not running (N)"
  group. Before the first observation rows make no claims. (3) Hidden and Always hidden follow the LAYOUT order and reorder
  optimistically, because their order is our own data (there is no observation to wait for; only the membership change itself is
  verified, shown as a ghost in the destination strip and "⟳" on the capsule still on the bar). (4) The layout the window submits
  is shown at once (`pendingLayout`) so consecutive drops build on each other; everything else is the engine's state.
- Units: capsules of one hide unit get a link marker and an outline; the tooltip says "Hides together with ...". A move
  (`Layout.move`) takes the whole unit, and every key it returns shows "⟳" too. Dropping beside a sibling is a no-op.
- Overflow boundary: the chevron (`ObservedOrder.overflowChevron`) is drawn as an orange line; items left of it are outlined
  and marked does-not-fit. Dropping left of it is allowed but flagged ("will stay behind the chevron"). Dropping right of the
  trailing system block clamps to before it (`ArrangeDrop.index`, which also clamps after the LEADING anchors, e.g. Wi-Fi leftmost, so index 0 = first movable slot; the debug hook
  `SOMMELIER_ARRANGE_MOVE` goes through the same function, 0-based among movable items); dropping on the item's own position is a no-op.
- Capabilities (`CapabilityRules`, bundle ids from `EngineState.items`): modules cannot be dragged; items that cannot be hidden
  can be reordered but a drop into a hidden strip is rejected with the reason (also shown as a small "⊘" on the capsule).
- Gestures: `draggable`/`dropDestination` with `ArrangePayload` (the store key as plain text); drop gaps between capsules draw the
  insertion bar, dropping on a capsule inserts before/after it by half. Drops are disabled while the filter is active. Context menu:
  Move to Visible/Hidden/Always hidden, Move left/right (skips anchors, never crosses the trailing block), Retry (failed),
  Reveal in menu bar (section-wide `setShowHiddenSection(true)` with auto re-hide after `autoRehideSeconds`; a per-item transient
  layout would be persisted by `setLayout`). Toolbar: Re-apply layout (`clearFailures` + `requestReconcile`), Adopt current order
  (confirmation; Visible = observed bar verbatim, Hidden = parked, Always hidden kept, not-running keys kept), Hide what does not
  fit, filter. Every engine call is a `Task`; a 0.25 s timer logs "MAIN ACTOR STALL" when it fires more than 100 ms late.
  "Reveal in menu bar" is disabled for Always hidden items.

## Overflow panel
- `EngineState.items` (`ItemInfo`, SommelierCore) carries display metadata (title, description, owner, width) for every
  currently known item; the engine refreshes it whenever it adopts a scan (`ItemInfo.merge` keeps the last known
  width of parked items; vanished items are dropped).
- `OverflowEntries.make` (pure) turns `layout.hidden` + `items` into entries in layout order; keys whose app is not
  running are skipped. `OverflowPlacement.panelFrame` (pure) right-aligns the panel to the status item under the bar.
- `OverflowPanelController` (app target) owns a non-activating `NSPanel` hosting `OverflowBarView`; it re-renders from
  the observed state and closes via monitors, a pointer poll and an inactivity timer (see docs/testing.md).

## Click-forwarding: `ItemActivator` (gdu.17)
Clicking an entry in the overflow panel opens the REAL item's menu or popover. Mechanisms, in the order the activator tries them
(`ItemActivator`, `SommelierCore`; the app wires it through `AppModel.activate`):
1. **Reveal + click (`revealClick`, adopted)**: take an engine hold on the item's hide unit (`LayoutEngine.beginTransientReveal`), show the
   unit live (`setAllowedLive([tracked: true])`, ~25 ms agent reaction), wait until the item is really drawn, post a synthesized click
   (CGEvent move/down/up via `.cghidEventTap`) at its centre (left or right), wait for the menu to close, hide the unit again
   (`setAllowedLive([tracked: false])`) and release the hold. The menu opens exactly under the item. "Really drawn" is NOT the app-side
   frame alone (a live-hidden item keeps a stale on-bar frame); it is the app-side frame on the strip AND MenuBarAgent hosting one more item
   than before the write (`hostedBarCount`); without a usable baseline a stale on-bar frame is believed only 0.6 s after the write.
   The reveal is per unit (app): siblings appear too while the menu is open.
2. **`axPressParked` (fallback, left click only)**: `AXUIElementPerformAction(kAXPressAction)` on the app-side element while it stays parked.
   Used when live hide/show is unavailable (no app-group entitlement), the item has no Control Center entry, the live write throws, or the
   reveal does not land within 1.5 s. CAVEAT: the menu/popover appears at an unrelated place (the item's frame is the parked frame at
   y ~1188: left screen edge below the bar, or mid-screen; docs/findings-visibility.md). The AX call may return -25204 although the menu
   opened, so a press error counts as failure only if no menu/popover child appeared within 1.5 s. A right click cannot be forwarded this way
   (`failed(.unavailable)`).
3. **`axPressOverflow`**: an item macOS moved into its own overflow (kind `.notFitting`) is on the bar but not drawn: AXPress, no reveal.
A drawn item (Control Center says allowed) is simply clicked (`barClick`).

Menu close: a `CloseMonitoring` source (app: global `NSEvent` monitor for mouse-up and Escape, installed only during an activation;
`mbprobe`: a listen-only CGEvent tap), OR the menu/popover child (counted against its count before the click, because some apps keep an empty
zero-sized `AXMenu` child) disappearing, polled every 250 ms; then a 300 ms settle. An outside mouse-up is believed only if the menu is gone
(a popover survives a click inside it); Escape is always believed. Hard cap 60 s. The re-hide is written once; a throwing write still releases
the hold and the result carries `rehideFailed` (the engine's next pass hides it); the activator never retries.

Engine hold: while a unit is held the engine hides `ObservedOrder` entries of that unit from the planner (it neither hides nor orders them), shows
them as `.pending` in `EngineState.perItem`, and auto-expires the hold after the timeout (65 s). `endTransientReveal` requests a reconcile.
KNOWN LIMITATION (bead filed): for items without an AX identifier/description (Tot, Yoink, Moom) the scanner cannot see a live hide, so after
the hold ends the next pass sees the item "on the bar", plans a hide and the live verification fails, which falls back to ONE agent respawn
(`live verify failed ... falling back to respawn`, ~4.5 s flash). The item itself is hidden again as soon as the live write lands.
Latency: the user-felt metric is panel click -> menu visible (activation starts on mouse-UP); it is 0.55-3 s in practice (locating scan 0.2-1.8 s,
hosted reads, live show 60-300 ms), so the 700 ms target is met only for the fastest reveals; the click -> menu part is 22-130 ms. Landing needs a
settled frame (y 0...5, identical on two polls) AND one more hosted item than before the write (baseline read after the hold; an incomplete read
means AXPress, never a believed stale frame). A click that opens no menu within 1.5 s is `.failed(.noMenu)` (re-hide and release still happen);
a cancelled task re-hides and releases too.
Debug: `SOMMELIER_ACTIVATE="<storeKey>[|right]"` (3 s after launch, result in `build/sommelier.log`); `mbprobe activate <key> [--right]
[--ax-press] [--escape-after S]`.
