# Sommelier architecture: actuation strategy (bead sommelier-gdu.8)

Host facts: macOS 27.0.1. All numbers come from the findings docs: positioning = `findings-positioning.md` (gdu.5),
visibility = `findings-visibility.md` (gdu.6), drag = `findings-drag.md` (gdu.7), order store = `findings-prefstore.md` (gdu.1),
identity = `findings-identity.md` (gdu.4). Quality bar from the epic: **the UI never lies**; nothing is shown as moved/hidden
until a settled full scan of the real bar agrees; failures are surfaced.

## (a) Primary mechanisms

| Action | Primary | Evidence |
|---|---|---|
| Reorder (on-bar third-party item) | Synthesized Cmd+drag via CGEvent on `.cghidEventTap`: 10 steps, 15 ms apart, 100 ms hold; drop at hovered item's `midX +/- 6 px` on the far side (`DragTarget.dropX`); wait >= 2 s; confirm with a full scan; retry once with the next drop point. No flash (bar changes once at mouse-up +90 ms); MenuBarAgent persists the new order itself, no restart. | findings-drag Exp A 20/20, B 23/23 (>=10 steps; 5-step drags succeed only 1/7, i.e. fail 6/7), C 10/10 on KeepingYouAwake, D (persist + no flash). 53/53 total. |
| Hide / show | Control Center `trackedApplications[...].isAllowed` flip (`ControlCenterTrackedAppsStore.setAllowed`) + ONE batched `killall MenuBarAgent`. ~2-3 s, 1-2 s bar flash, other items keep slots, shown items return to their previous slot. Only apps that already have a tracked entry. **Live path (gdu.39, primary when the process has the `com.apple.security.application-groups` = `group.com.apple.controlcenter` entitlement, `AppGroupEntitlement`):** `ControlCenterTrackedAppsStore.setAllowedBatchLive` (CFPreferences set + synchronize, read back through CFPreferences), then `LiveActuator` polls full scans every 0.5 s until the first COMPLETE hosted read decides (an unsatisfied complete read gets one more complete read before giving up; hard ceiling 8 scans / 20 s). No respawn, no flash. Measured 2026-11-04 (MBDummy, Bartender quit, ad-hoc signed): write to verified 0.61-5.15 s over 40 ops (min 609 ms, median ~2.0 s, max 5146 ms; scan-bound, implementer soak 40/40 live, MenuBarAgent pid unchanged; the reviewer's run was 4/6 live under the old 6 s wall bound because of incomplete-read streaks of 2-3 s scans, hence the scan-count bound; fallback should now occur only when no complete read arrives within the ceiling); engine `apply` 5.6-6.5 s wall incl. ~4.5 s observe, actuation 0.63-0.71 s. Fallback = the respawn path above (unentitled binary: ~2.9 s and ~8.4 s measured; also after a live write throws or two complete reads disagree, or no complete read arrives within the ceiling). Developer ID/notarized: see findings-live-trigger section 8. The file-read fallback in `setAllowedBatchLive` (when CFPreferences returns nil) and the respawn fallback's file write can push a lagging on-disk blob into cfprefsd; low probability, same as the pre-existing respawn path. | findings-visibility A2/A4/A6 (applies only after agent restart; no live reload A1/A3/A5); A7/A8 (hand-made entries are not honored); conclusion. |

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
`.permissionDenied`, `.unsupportedItem`, `.notFound`. Restart-based actions: one retry of the restart if the verifying scan still shows the
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
- Unknown keys (not in the layout) follow `newItemPolicy` and are returned in `newItems` (the planner never mutates the layout);
  unknown parked keys are never shown. Layout keys not observed are listed in `absent` and ignored.
- Minimality: anchors are always kept; per gap between anchors, a longest increasing subsequence of movables stays put; moves == misplaced items. Moves are emitted
  left to right in target order, preferring `.after(left neighbour)`, then `.before(right)`, and `.leftmost`/`.rightmost` only as a last resort.
- `PlanSimulator.apply` replays actions on an `ObservedOrder` (show slot injectable); `ReconcilerRandomTests` uses it for seeded convergence checks.
- Dev tool: `mbprobe plan [--show-hidden] [--file PATH] [--json]` prints the plan and executes nothing.

### LayoutEngine

`LayoutEngine` (actor, `LayoutEngine.swift`) runs the observe -> plan -> act -> verify loop; `EngineState` (`@MainActor @Observable`) is the only thing the UI binds to.

- **Pass**: (1) if the mouse is down (`busy`), wait up to 3 s polling every 0.1 s, else skip and retry once; (2) `observe()` (two agreeing full scans); (3) plan with failed keys forced to `canMove = canHide = false` (they become anchors); (4) persist `newItems` into the layout (once per pass) per `newItemPolicy`; (5) act; (6) publish.
- **Two phases**: *membership* is one `applyHiddenBatch` (one agent restart, never called with an empty batch), then re-observe and re-plan; *order* is one `move` at a time, re-planning from the verified snapshot after each. Both continue in the same pass when the post-membership plan is `.order`. At most `maxActionsPerPass` (50) actuator calls per pass; 3 consecutive failures stop the pass (`lastError`, no chaining); a membership batch that reports failure/drift ends the pass with `lastError = .batchDrift` (cleared only by `clearFailures`/`setLayout`) and never chains into drags; at most 2 chained passes. `mbprobe apply` runs the actuator drag-only unless `--allow-fallback`.
- **Observed truth only**: `EngineState.observed` is set solely from an actuator-returned snapshot or a fresh observe, never from the plan. `perItem` is `.inPlace/.pending/.moving/.failed/.unsupported`; `unsupported` (capability skips) does not block `isConverged`, `failed` does.
- **Suppression**: a key whose actuation failed stays suppressed until `setLayout`, `clearFailures()`, or its app disappears from the bar. This stops the 10 s poll from re-running a failing agent restart forever. `userBusy` is not a failure and is not suppressed.
- **Fatal errors**: no Accessibility permission or a competing manager (Bartender) sets `lastError`, makes no actuator call and stops the engine until `clearFailures()`.
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

## Overflow panel
- `EngineState.items` (`ItemInfo`, SommelierCore) carries display metadata (title, description, owner, width) for every
  currently known item; the engine refreshes it whenever it adopts a scan (`ItemInfo.merge` keeps the last known
  width of parked items; vanished items are dropped).
- `OverflowEntries.make` (pure) turns `layout.hidden` + `items` into entries in layout order; keys whose app is not
  running are skipped. `OverflowPlacement.panelFrame` (pure) right-aligns the panel to the status item under the bar.
- `OverflowPanelController` (app target) owns a non-activating `NSPanel` hosting `OverflowBarView`; it re-renders from
  the observed state and closes via monitors, a pointer poll and an inactivity timer (see docs/testing.md).
