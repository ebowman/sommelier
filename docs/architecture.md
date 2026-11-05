# Sommelier architecture: actuation strategy (bead sommelier-gdu.8)

Host facts: macOS 27.0.1. All numbers come from the findings docs: positioning = `findings-positioning.md` (gdu.5),
visibility = `findings-visibility.md` (gdu.6), drag = `findings-drag.md` (gdu.7), order store = `findings-prefstore.md` (gdu.1),
identity = `findings-identity.md` (gdu.4). Quality bar from the epic: **the UI never lies**; nothing is shown as moved/hidden
until a settled full scan of the real bar agrees; failures are surfaced.

## (a) Primary mechanisms

| Action | Primary | Evidence |
|---|---|---|
| Reorder (on-bar third-party item) | Synthesized Cmd+drag via CGEvent on `.cghidEventTap`: 10 steps, 15 ms apart, 100 ms hold; drop at hovered item's `midX +/- 6 px` on the far side (`DragTarget.dropX`); wait >= 2 s; confirm with a full scan; retry once with the next drop point. No flash (bar changes once at mouse-up +90 ms); MenuBarAgent persists the new order itself, no restart. | findings-drag Exp A 20/20, B 23/23 (>=10 steps; 5-step drags succeed only 1/7, i.e. fail 6/7), C 10/10 on KeepingYouAwake, D (persist + no flash). 53/53 total. |
| Hide / show | Control Center `trackedApplications[...].isAllowed` flip (`ControlCenterTrackedAppsStore.setAllowed`) + ONE batched `killall MenuBarAgent`. ~2-3 s, 1-2 s bar flash, other items keep slots, shown items return to their previous slot. Only apps that already have a tracked entry. **Live path (gdu.39, primary when the process has the `com.apple.security.application-groups` = `group.com.apple.controlcenter` entitlement, `AppGroupEntitlement`):** `ControlCenterTrackedAppsStore.setAllowedBatchLive` (CFPreferences set + synchronize, read back through CFPreferences), then `LiveActuator` polls full scans every 0.5 s until the first COMPLETE hosted read decides (an unsatisfied complete read gets one more complete read before giving up; hard ceiling 8 scans / 20 s). No respawn, no flash. Measured 2026-11-04 (MBDummy, Bartender quit, ad-hoc signed): write to verified 0.61-5.15 s over 40 ops (min 609 ms, median ~2.0 s, max 5146 ms; scan-bound, implementer soak 40/40 live, MenuBarAgent pid unchanged; the reviewer's run was 4/6 live under the old 6 s wall bound because of incomplete-read streaks of 2-3 s scans, hence the scan-count bound; fallback should now occur only when no complete read arrives within the ceiling); engine `apply` 5.6-6.5 s wall incl. ~4.5 s observe, actuation 0.63-0.71 s. **No bar flash from hides (gdu.55):** a verification timeout is never a respawn reason. After `setAllowedLive` succeeds the actuator reads `isAllowed` back through CFPreferences (`readAllowedLive`, 3 attempts over 1.5 s; an unreadable store cannot contradict the write). Readback shows the intended values: the batch is APPLIED and the poll only CONFIRMS: confirmed -> `.verified`, mechanism `live`; max scans (8) / timeout (20 s) without a contradiction -> `.verified` with mechanism `liveUnverified` (note `applied per Control Center store; confirmation pending`), the hide's owners recorded assumed-hidden, no respawn, no strike; two complete reads that still show the unit (store applied, agent did not act) or another item leaving the bar -> `.failed(.notVerified)` with mechanism `live`, assumed-hidden cleared (the scanner's `isAllowed` readback clears it too), no respawn, the engine re-plans normally. During a self-positioning streak (previous full read `completeExceptSelfPositioning`, non-self-positioning unit) the confirm polls use the fast hosted read (`scanVisible`, can only confirm) with a full scan every 3rd poll. **Respawn (file write + `killall MenuBarAgent`) only when the live write itself failed:** `liveHideShowAvailable == false`, `setAllowedLive` threw, or the readback never showed the intended value; and only if `LiveActuator.Config.allowAgentRestart` allows it (nil = automatic = `!liveHideShowAvailable`, i.e. on only when the entitlement is missing; `allowAgentRestartProvider` is read per batch and carries the Settings toggle "Allow menu bar restart as a last resort", `@AppStorage("allowAgentRestart")`, default off with the entitlement; `mbprobe hide|show|apply --allow-agent-restart`). Not allowed -> `.failed(.liveWriteFailed(reason))`: the engine logs it, marks the key failed (struck out at once like a respawned batch, not `.unsupported`) and does not restart. `lastBatchUnconfirmed` (`MenuBarActuator`) lets the engine keep `.liveUnverified` keys `.inPlace` and publish them in `EngineState.pendingConfirmation`; the Arrange badge stays a check mark with an orange dot and the tooltip "Applied; confirmation pending" until a later settled complete read confirms (hide: unit off the bar by evidence, not only by assumption; show: on the bar), and the engine does not strike such a key while the read still disagrees. Unit tests: `LiveActuatorTests` (gdu.55 section), `LayoutEngineTests`. The order-store fallback for `move` (`allowFallback`, mbprobe only) and the respawn path itself are unchanged, including the `fullStrike` for genuinely respawned batches. Developer ID/notarized: see findings-live-trigger section 8. The file-read fallback in `setAllowedBatchLive` (when CFPreferences returns nil) and the respawn fallback's file write can push a lagging on-disk blob into cfprefsd; low probability, same as the pre-existing respawn path. **Scanner detection of a live hide has three evidence kinds (of7):** (1) hosted-by-name: an item with an AX identifier (or description) that was seen hosted and is absent from a COMPLETE hosted read is `notHosted` (gdu.38); (2) parked frame (x -1..3, y ~1188), the post-respawn state; (3) write-time hosted-ELEMENT evidence for identifier-less items (Tot, Yoink, Moom; their hosted and app-side elements share no name, only an unreliable frame join): `LiveActuator` takes the attributed hosted tree of the full scan it already made before the write (`MenuBarSnapshot.hostedLayout`; if that read is incomplete: complete scans retried for up to 4 s, then the scanner's last complete tree if at most 10 s old; the trace says which baseline was used), writes, and probes complete hosted reads at 0.3/0.8/1.5/2.5/4/6 s plus the poll's own complete scans. Verified iff the post-write tree equals the pre-write tree minus exactly the unit's joined elements, in order (`HostedEvidence.removedExactly`: same identifiers/descriptions; widths compared only for identifier-less elements, because named readouts change width on their own; modules must still be present), and no other app-side item left the bar. A mere count match is NOT evidence (another element vanishing while one appears has the same count). Only pure-hide batches; a batch that also shows items keeps the complete-read poll alone. Evidence records the owner in `ScanState.assumedHidden` (pid, bundle id, Control Center tracked key, time, hosted count after, item count; persisted in `scan-cache.json`, so `mbprobe list` sees it). `MenuBarScanner` then reports that owner's identifier-less, on-bar-framed items `isOnMenuBar = false`, `hidden = assumedNotHosted`. Cleared by: a live/respawn SHOW by us (actuator and `ItemActivator` clear it at write time), a respawn, the owner quitting, a different bundle id on that pid (reuse guard), the Control Center `isAllowed` readback (CFPreferences, rate-limited to once per 10 s per owner) reading true (someone else showed it), or a 2 h hard safety expiry (logged). There is deliberately NO frame/width/count contradiction rule: a foreign element (our own status item sat on Tot's stale frame with the same width) can overlap a stale frame, and the store is what the agent enforces, so the record stands exactly as long as the store says hidden. If the actuator is asked to hide an identifier-less unit whose store value already reads hidden, it writes nothing, records the owners and returns `.verified` with mechanism `alreadyApplied` (trace "already hidden per Control Center store; recorded assumed-hidden"). Sommelier's own status item button carries `MenuBarScanner.ownStatusItemIdentifier`; the frame join never attributes that hosted element (or an identifier-less one described "Sommelier") to another candidate. Asymmetry: the flag is ONLY set by our own successful write plus element evidence, never inferred from frames or absence alone, so an untouched bar cannot produce a false hidden; a wrongly cleared flag merely restores the old behaviour (reported on-bar, respawn fallback). `ItemActivator` records the flag after its re-hide write when the hosted tree is again exactly the pre-reveal tree, and the activator shares the engine's `LivePlatform` (one scanner, one `ScanState`), so the engine's next pass plans nothing; while a transient reveal hold is active the engine plans no actions and records no new items at all (a revealed element may appear as an unknown heuristic item that must never be dragged). The flag is keyed by pid (the unit is the owner; identifier-less items' own keys are frame-based and move). | findings-visibility A2/A4/A6 (applies only after agent restart; no live reload A1/A3/A5); A7/A8 (hand-made entries are not honored); conclusion. |

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
* **Hide with no tracked entry:** the system creates the entry itself ~0.2-0.3 s after a status-item app launches (gdu.24, findings-untracked-hide.md),
  so "untracked" is normally transient: re-read `trackedApplications` for >= 1 s before declaring it. If still absent, `Capability.canHide == false` with the reason
  "cannot be hidden: not tracked by Control Center" and the UI offers "Open System Settings > Menu Bar". Creating the entry ourselves works (entitled cfprefsd write, `isAllowed=false`, honoured and kept)
  ONLY with the exact system shape including `menuItemLocations` matching the launching executable (wrong shape is overwritten to `isAllowed=true` within ~0.25 s; a shape without `menuItemLocations` makes the system discard the whole blob). Proven for ad-hoc apps only; follow-up
  (not yet filed): implement the recipe in findings-untracked-hide.md after proving the signed-app `menuItemLocations` form.
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
   items right after a move: findings-drag pitfall 2).
   **Verdict rule (gdu.27):** after two agreeing fast scans the verdict full scan must itself agree with the last fast observation (`SettleDetector.verdictAgrees`: on-bar key order of items both scans can know; items stale in either scan, noise width <= 1 and self-positioning owners are ignored; parked set only when the fast scan reported parked items). A disagreeing verdict triggers a new fast pair and a new verdict (+ ~0.15 s + 2 fast scans + 1 full scan) until `maxWait` / `maxFullScans` (3 total full scans), then the outcome is not settled (`SettleOutcome.trace`: "verdict disagreed with fast observation"). An incomplete fast read (e.g. an iStat AX-timeout streak) is compared like any other, so it costs no extra full scan. Up to two retries of an empty full scan count toward `maxFullScans` but are not limited by it, so the total can exceed it by two. No extra scan when the verdict agrees.
   Floors/caps: after a drag wait >= 2.0 s after mouse-up (AX lags 0.4-2.0 s,
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
   **`.verified` never comes from one full scan (gdu.26).** A move that already looks satisfied on `prepare()`'s single scan is re-observed through `SettleDetector` first (disagreement -> re-plan from the settled observation, or `.timeout` if it keeps flapping); a batch that looks satisfied on one full scan needs a second full scan that agrees (`SettleDetector.agree`) before `batch already satisfied`, and a contradiction restarts the batch once from the newer scan. Cost: one extra settle / full scan (~0.3-1 s) on the no-op paths only. The live-write confirm poll (first complete hosted read after a write; gdu.39/51/55) and the store-based `alreadyApplied` / `liveUnverified` results are different evidence by design (a state change observed after the write, resp. the Control Center store), not a settle claim.

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
(a restart blanks the bar for 1-2 s). Restart happens after the agent-store file is quiet. Validation happens before the write (back up the plist in memory); a missing key or conflicting
requests still fail the whole batch, but units the capability rules refuse (no tracked entry, Apple app, no owner; gdu.72) are split off with their own
reason (`BatchOutcome.perKey` `.failed(.unsupportedItem)`, `MenuBarActuator.lastBatchRefused`) and the applicable units go out in ONE write; the aggregate
`result` covers only the applied units (all refused: no write, uniform `.failed(.unsupportedItem)`). The engine records refused units as skips (`.unsupported(reason)`,
no strike, no `batchFailed`, not retried until `clearFailures`/layout change); a genuine write failure still raises `batchFailed`. Capability snapshot per pass (gdu.74): `LayoutEngine.refreshHideUnits` reads the tracked entries once at the start of each pass and derives BOTH the hide-unit rule and the planner's capability rules from that one snapshot (`Config.capabilitiesFor`; `EngineFactory.makeLive` wires it, tests/mbprobe keep the fixed `makeCapabilityRules(resolver:)`), so an entry appearing or disappearing after launch is seen by planner and actuator alike. Refused-unit re-evaluation: at the start of each pass `reevaluateRefused` drops an `actuatorRefused` key whose item vanished, or which was refused under an older snapshot and whose capability now allows it (it is planned again, no Retry needed); a unit the rules still refuse, or refused under the current snapshot, stays `.unsupported` without a strike. `clearFailures` (Retry/`setLayout`) still clears all. Still-refused parked units are withheld from the Reconciler (to avoid an endless show) and re-added as explicit skips with the refusal reason; the Reconciler's reveal skip reason is taken from `capabilities(k).reason` (Apple app vs not tracked). Verification is per-key.

## (d) Identity model and the three sections

`ItemKey` (`ItemKey.swift`): `.status(ownerKey, autosaveName)` and `.module(name)` are byte-identical to `TrailingItemPreferredPositions`
keys; `.heuristic(bundleID, fingerprint, ordinal)` is synthesized. `ownerKey` is the bundle id for installed apps and the executable name
otherwise (findings-identity; the dev Sommelier build and MBDummy therefore key as their executable name).
`KeyConfidence`: **exact** (store key + AXIdentifier corroboration), **inferred** (real store key, pairing by order or single candidate),
**corroborated** (gdu.28: a synthesized fingerprint key whose owner-to-hosted-frame pairing was independently corroborated), **heuristic**
(attribute fingerprint, not a store key). Rules for the UI:

* exact: full controls, "verified" claims allowed.
* inferred: movement is allowed (drags use the live item's frame, not the key), but any claim about a persisted position is made only after a
  full scan; fallback (order-store edit) is allowed only for exact keys or inferred keys confirmed by a post-hoc scan, because writing
  the wrong autosave name would silently move a different item.
* heuristic: drag allowed (frame-based) with greyed "unverified identity" state; never written to the store; hide only if a tracked entry
  is known; never persisted as a user layout (session only).
* corroborated (gdu.28): the key text is the same `heuristic:<bundle>::<fingerprint>#<ordinal>` string (so saved layouts and caches load
  unchanged), but `MenuBarItem.joinEvidence` says how the scanner paired the owner's AX item with the MenuBarAgent hosted element that
  supplies the frame: `identifier`, `description` (non-empty, unique among owner items and hosted elements), `frameUnique` (mutual and
  exclusive overlap >= half the narrower width, widths within 2 pt) or `frameAmbiguous`/`none`. `ResolvedItem.frameTrusted` (= has an AX
  identifier, or the join is corroborated) is what LiveActuator's frame-based post-restart drift check now requires, so identifier-less
  items with a corroborated join (inferred `status:...::Item-0` keys as well as `.corroborated` heuristics) are covered by it; bare
  heuristics, ambiguous joins and self-positioning owners are not. Two behaviour changes follow, both intended: (a)
  `ActuationVerifier.uncorroborated` is looser than before: a `.corroborated` identifier-less heuristic item joined by a unique description (the identifier pass needs an identifier on both sides, so it cannot apply to identifier-less items) CAN now support verified move/visibility results (before, every identifier-less heuristic item was blocked); a
  `frameUnique`-only item, an ambiguous one and a `.none` one are still blocked. (b) `MenuBarObserver.orderable` (~:248) now admits a
  heuristic-keyed item that has an AX identifier and was joined by identifier (it resolves as `.corroborated` instead of `.heuristic`). The key itself contains no frame, pid or AX handle, so it survives
  MenuBarAgent respawns and the item's own moves; the only instability is twins (identical fingerprints of one owner), whose ordinals
  follow left-to-right position (a drag past a twin swaps the two keys).
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
  order), modules included, without `append`'s trailing-block insertion rule. The result is hide-unit normalized: an app with one
  item on the bar and a sibling parked would be a split unit, so the parked key moves to `visible`
  (`LayoutBuilder.buildReportingNormalization` returns the moved keys; `mbprobe layout init-from-current` prints them as a warning).
  `LayoutEngine.setLayout` normalizes too (logs the moved keys and publishes them as `EngineState.lastNormalization`, replaced by
  every `start`/`setLayout`, for the Arrange status line; `start()` fills it from the load).
- Hide unit (`HideUnit`, `HideUnitRule`, `hideUnits(_:rule:)` in `ItemKey.swift`; gdu.75): Control Center's `isAllowed` flag is per
  tracked ENTRY, so the unit is the entry: keys that resolve (`TrackedEntryResolver.trackedKey(for:bundleID:)`, the one lookup the
  actuator's `trackedKey(for:)` also uses) to the same entry form ONE unit whose id is the entry key. A helper listed in a parent's
  `menuItemLocations` (Hazel Helper under com.noodlesoft.Hazel) is therefore in the unit of the parent's own item and they hide, show
  and move together. Fallback for a key with no entry: the owner-key unit (`ItemKey.hideUnit`: the `ownerKey` for status items,
  `module:<Name>` for each module, the bundle id for heuristic keys), i.e. an ordinary app's items are one unit as before.
  `HideUnitRule` is a snapshot value (resolver + bundle ids); `.ownerKeys` is the no-knowledge default. The engine builds it from
  `Config.trackedResolver` at every pass and layout adoption, uses it for the planner and normalization, and publishes it as
  `EngineState.hideUnits`, which Arrange, the overflow panel and drops use, so every consumer groups exactly like the planner.
  The actuator additionally never changes an item the batch did not request: a unit whose requested members differ, or whose flag
  flip would also move an unrequested member, is refused whole ("hides together with <entry>: move the whole group"). A unit is hidden
  only if ALL its items are in `hidden`/`alwaysHidden` (a `hidden`+`alwaysHidden` split is fine). `Layout.normalizedHideUnits(units:)`
  moves the hidden-section keys of a unit that also has a `visible` key to `visible` (before the trailing system block, original
  order); `validated()` applies it after `dedup()`, `validatedReportingNormalization()` also returns the moved keys (no hidden state
  on `Layout`), and `Layout.decode` adds a warning, so the load path reports it once (mbprobe prints it, the engine `NSLog`s it).
  `Layout.move(key, to:index:)` moves the WHOLE unit (key at the index, siblings right after it) and returns every moved key, `key`
  first (`mbprobe layout move` prints "also moved: ..."). `append`/`reorder` place only the given key (builders, in-section order).
- `newItemPolicy`: `visibleAtEnd` (default) or `hidden`, applied by the planner to keys not yet in the layout. `visibleAtEnd` is "at the end of the bar" only
  modulo the trailing system block: since gdu.41 a new visible key lands before the trailing run of anchors (Control Center modules,
  clock), both in the planned target and in the saved layout (`Layout.append(_, to: .visible)` inserts before the trailing `.module` run).
  A new key of an app the layout already lists (even if the listed siblings are not on the bar now) ignores the policy and joins its
  unit's section (`alwaysHidden` if any sibling is, else `hidden` if all are hidden, else `visible`).
- Keys of apps that are not running stay in the file untouched (absent is not unknown).
- Schema: `schemaVersion` (currently 1). Lenient decode (missing fields default; duplicates dropped with warnings via
  `Layout.decode`). Lower versions migrate in memory on load (no rewrite); higher throws `unsupportedSchema`.
- Writes are atomic: temp file `layout.json.tmp-<uuid>` in the same directory, then `rename(2)`.
- A corrupt file (bad JSON or unparsable key) is copied to `layout.json.bak` and `load()` throws `LayoutError.corrupt`;
  a missing file loads as `Layout.empty`.
- Dev tool: `mbprobe layout show|init-from-current|move|remove [--file PATH]`. `init-from-current` writes stale self-positioning items (`SelfPositioning.defaultOwners`, `BarSignature.staleVerdict`) of an agreed scan with a stderr note and refuses (exit 1, keys named) on any other stale item; on no-agreement it names the last scan's stale keys and the keys that moved/changed class between the last two scans (`ScanDisagreement`, `OrderDiff`). `observeDetailed` still throws a bare `noAgreement` (the explanation is only on `observeDiagnosed`).

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
  every anchor in its observed slot. In a membership phase (hides/shows pending) these anchor skips are NOT reported (gdu.44): the bar
  is about to change and a transient or churned read (e.g. no chevron in that scan) can show anchors out of order that the order pass
  finds fine, so the order pass decides. Unsettled observations are never planned on by the engine, so no extra suppression is needed.
- Self-positioning owners are anchors (gdu.33): items of iStat Menus (`SelfPositioning.defaultOwners`, ONE definition in `ReadCompleteness.swift`) move between slots on
  their own across agent restarts, so the planner treats them as `canMove == false` and does not place them from the layout at all (they keep their observed slot, like
  any unplaced anchor): never dragged, no "out of order" skip and no convergence dependency on their slot. Hide/show is unchanged. The actuator's drift exemption
  (`LiveActuator.Config.selfPositioningOwners`), `LayoutEngine.Config`, `MenuBarScanner` and `BarSignature` default to the same set. The Arrange row shows "Positions itself".
  Arrange refuses an ORDER-ONLY drop of such a row inside Visible (`ArrangeDrop.outcome` -> `ArrangeDrop.positionsItself`; the planner would ignore the order, so
  it is not saved); a drop that changes section (hide/show) is accepted. `CapabilityRules` is unchanged (`canMove == false` there blocked drag-to-hide, gdu.33).
  The engine's gdu.51 gate only checks the relation TARGET (`SelfPositioning.isSelfPositioning`): a move next to an iStat item waits for a `.complete` read; the subject is never one.
  **Straddling a self-positioning item (gdu.67, option b):** a layout [B, iStat, A] from a bar [A, iStat, B] is unreachable: an anchor keeps its observed slot only within one pass, so after B moves the next pass re-plans around iStat and ends [B, A, iStat]. Rejected option (a), an absolute-slot invariant across passes: iStat items move on their own across respawns, so the invariant would fight them. Instead the limitation is explicit: `ArrangeDrop.outcome` (and so drop and keyboard `step`/`canStep`) refuses an order-only Visible move that puts a movable row on the other side of a self-positioning row relative to the OBSERVED bar ("cannot cross <name>: it positions itself; move it in iStat Menus instead"; hide/show, module anchors and rows not on the bar are unaffected). A persisted layout that already straddles behaves as before (converges at [B, A, iStat]); the engine then rewrites the layout to the bar's order around the item (`Layout.normalizedAroundSelfPositioning`, only after a converged pass on a complete read), records the moved keys in `lastNormalization` and the Arrange status line says so.
- Trailing system block: the maximal suffix of the bar made only of anchors (Control Center modules, clock) is unreachable for third-party
  items on macOS 26+. A movable key the layout places right of its first item goes into `skipped` ("cannot be placed right of the system
  items (<anchor>)"; the name is the block's first MODULE, since a self-positioning item can sit at its start, gdu.61) and is relocated in the target to the last slot before the block (relative order kept), so no drag ever has an anchor
  as subject or a destination in the block (asserted after `moves`). The block is taken from the observed bar BEFORE shown items are
  appended, so in a membership pass a key the layout puts right of the clock is already skipped and relocated before it in
  `desiredOnBar` (shows no longer appear right of the clock until the order pass). When anchors are out of layout order, movable keys
  the layout puts right of a block containing system modules also get their own "cannot be placed right of the system items" skip. Non-trailing anchors (e.g. `module:WiFi` mid-bar) are unaffected.
  Correspondingly `Layout.move(_, to: .visible, index: nil)` inserts before the trailing run of `.module` keys instead of appending
  (`Layout.trailingSystemBlock`); an explicit index is literal and `mbprobe layout move` warns when it lands in the block.
- Hide units: membership is decided per unit before any hide/show is computed. A unit is wanted-hidden only if all its observed
  layout-listed keys are hidden-listed and the hidden section is not being revealed with `showHiddenSection`; a unit with any `alwaysHidden` key stays hidden even while revealing (its `hidden` keys get a "kept hidden together with <key>: an always-hidden item keeps its app hidden" skip, and `OverflowEntry.pinnedHidden` marks them in the panel); otherwise it is wanted
  on the bar and each hidden-listed key goes into `skipped` ("hidden together with <ownerKey>: all items of an app hide or show at
  once"). `hides`/`shows` cover every observed key of the unit, so the actuator batch is complete and never conflicts. Unknown items
  of a listed unit follow the unit (also when the listed siblings are absent from the observation, gdu.44); a wholly unknown unit follows `newItemPolicy` only if one of its items is on the bar. If a unit
  must hide but one item cannot (`canHide == false`), none of it is hidden (all anchored, reported in `skipped`). The overflow panel
  (`OverflowEntry.unit/unitSize`) keeps a unit adjacent, with a divider between units and a count badge plus "Hidden together" tooltip.
- Unknown keys (not in the layout) follow `newItemPolicy` and are returned in `newItems` (the planner never mutates the layout);
  a wholly unknown unit that is parked is never shown (a unit the layout lists is
  decided by its listed siblings, observed or absent, and an unknown key of it follows that decision). Layout keys not observed are listed in `absent` and ignored.
- Minimality: anchors are always kept; per gap between anchors, a longest increasing subsequence of movables stays put; moves == misplaced items. Moves are emitted
  left to right in target order, preferring `.after(left neighbour)`, then `.before(right)`, and `.leftmost`/`.rightmost` only as a last resort.
- `PlanSimulator.apply` replays actions on an `ObservedOrder` (show slot injectable); `ReconcilerRandomTests` uses it for seeded convergence checks.
- Dev tool: `mbprobe plan [--show-hidden] [--file PATH] [--json]` prints the plan and executes nothing.

### Observer (`AgreedScanObserver`, gdu.46)

`observe()` is strict (settled or throws `noAgreement`); `observeDetailed(progress:)` is what the engine uses.
- **Agreement**: two consecutive full scans must show the same (1) ORDER of on-bar identified keys (AX identifier present, not a heuristic key, owner not self-positioning (`LiveActuator.Config.selfPositioningOwners`, iStat), not in `volatileKeys`), (2) PRESENCE of every other on-bar key (identifier-less items and iStat count for presence, not order), (3) set of parked keys and set of stale parked keys. A stale item ON the bar blocks agreement, EXCEPT a stale item of a self-positioning owner (gdu.51: it counts for presence, never for order). Width <= 1 items are ignored.
- **Adopted-observation reuse for user-initiated passes (gdu.71)**: `observeDetailed(progress:seed:)` takes an optional `ObservationSeed` (items + read level + a `normalize` closure for wrappers such as `RecordingObserver` that filter the engine's view). The seed stands in for the first of the two agreeing scans, so ONE fresh scan must agree with it by the normal rule (same `BarSignature`); a disagreeing fresh scan makes the loop continue as if it were the first scan (the usual two fresh scans; the seed never counts toward `maxScans`/the budget). `BarObservation.scans` counts fresh scans only. The engine offers a seed only when ALL hold: the pass is USER-INITIATED (`requestReconcile(userInitiated:)`, set by `setLayout` (also its coalesced `fireDelayed`) and `setReveal`; the poll, app launch/quit, display/wake, agent-restart and transient-reveal-end requests never are), `Config.userPassReuseWindow` > 0 (default 2 s; 0 disables), the engine's `lastAdopted` observation is at most that old and its read level is `.complete` or `.completeExceptSelfPositioning`, and no agent restart is pending. Only the FIRST observation of a pass is seeded (the observation repeated after a busy wait is not). Why it is safe: the adopted observation already passed the agreement rule (or is a post-write read, verified or not: the fresh scan must agree with its full signature), a fresh scan must still agree with it, so the pair is two agreeing scans taken at most 2 s apart, as before; and everything after the observation is unchanged: complete-read gate (gdu.51), live write + readback + two-scan verified rule (gdu.26/27/55). A bar that changed since the adoption (including by our own earlier write) simply disagrees and costs the usual extra scan. Observability: the engine logs `observe=<ms> scans=<n> reuse=yes|no`, publishes `EngineState.lastObserveMillis` / `lastObserveReused`, and the reveal log line reads `reveal converged N ms after the click observe=Mms reuse=yes|no`. The `lastAdopted` observation comes from settled observations AND from snapshots adopted after an actuator call, including the snapshot of a failed result, as long as the read level is usable; cleared by `agentRestarted`). A snapshot is a single scan, which is safe as a seed because it is accepted only if a fresh scan agrees with its FULL signature (order, presence, parked, stale-parked), i.e. the pair is two agreeing scans exactly as before.
- **Read completeness levels (gdu.51)**: `MenuBarSnapshot.completeness` is `.complete` (hosted tree read without a failed group; `hostedReadComplete == true`/nil), `.completeExceptSelfPositioning` (the tree has failed groups, but EVERY stale hosted element and EVERY stale app-side candidate belongs to a self-positioning owner, there is no top-level failure, there is fresh hosted data, and every failed read is attributable to a self-positioning owner BY IDENTITY: no top-level failure, every named timeout carries a self-positioning element, and the unnamed timeouts are covered by self-positioning groups absent from this read (persisted groups or elements hosted in the previous tree; see the gdu.53 bullet below), with no other previously hosted element missing; item counts or the owner's cached items prove nothing), or `.incomplete`. `hostedReadComplete` stays strict (true only for `.complete`). `BarObservation.completeness` is the weakest level of the scans an observation rests on. Why: iStat's AX answers time out for tens of seconds, which made every scan incomplete and the engine wait (reads incomplete for 40+ s) although the hosted tree was fine for everyone else. Which consumer accepts which level:

| consumer | `.complete` | `.completeExceptSelfPositioning` | `.incomplete` |
|---|---|---|---|
| `LiveActuator` live-verify poll (first usable read decides) | yes | yes, unless the unit itself is self-positioning | no (counts as an incomplete scan; 8 scans -> `liveUnverified`, never a respawn, gdu.55) |
| hosted-element evidence (`HostedEvidence`, baseline + probes + poll layouts) / assumed-hidden recording | yes | yes, both layouts compared without the self-positioning owners' entries (`SelfPositioning.strip`), unless the unit is self-positioning | no |
| scanner `notHosted` judgement of a named key | yes | yes for items whose owner is NOT self-positioning (every failed group is provably theirs); never for self-positioning owners' items | no (only the sticky `hiddenKeys` rule) |
| `state.hiddenKeys` / `lastCompleteLayout` | updated | `hiddenKeys` updated; `lastCompleteLayout` not | unchanged |
| `AgreedScanObserver` agreement / settled | yes | yes (stale self-positioning items are non-blocking, presence only) | only without a stale on-bar item (as before) |
| Arrange tracker settled gate (`observationSettled`) | yes | yes (follows the observer) | follows the observer |
| engine ORDER actuation (drags) | yes | only when no planned move involves a self-positioning key (moved item or target); otherwise the pass ends `unsettled` and waits | no |
| `LayoutEngine` membership actuation | yes | yes | no |

- **Persisted self-positioning group identity and long streaks (gdu.53)**: `ScanState.selfPositioningGroups` (`[pid: [SPGroup]]`, persisted in the scan cache with the owner's bundle id) records the hosted groups (identity key, identifier, frame) last seen FRESH for each running self-positioning owner. It is replaced exactly on every complete read and merged on every attributed (middle-level) read, a group shown under another owner leaves the first owner's record, and a pid's record is pruned when that process is gone (or its pid now belongs to another bundle). It is independent of the 3-scan stale carry-over (`maxStaleScans`), which still bounds how long stale items are SHOWN. Unnamed timeouts are covered when their count is <= the number of self-positioning groups (persisted, or missing from the previous tree) absent from this read and not named, with no other previously hosted element missing; so an iStat streak of any length (10+ scans, 40 s+) stays `.completeExceptSelfPositioning` after the stale items have dropped out of the saved tree, while an unnamed timeout of anything else (count exceeds the missing iStat groups) or a vanished third-party element is `.incomplete` for that scan only. The middle level no longer requires that something is stale: once the 3-scan carry-over expires nothing is stale during a streak, and the failures are attributed by identity instead. A fresh process attributes on its first scan from the persisted record. The record is also pruned by the owner's own extras and bounded in age (gdu.54, next bullet). Attribution feeds `noteUnresolvedGroups`, so the 0.3 s cap holds for the whole streak (a group leaves the capped set when a read resolves it; a read with an unattributed failure caps nobody that scan).
- **Read noise and vanishing units (gdu.51)**: a timed-out hosted element with width <= 1, or with neither identifier nor description at the menu bar strip's left edge (minX within 1 pt of the strip's minX since gdu.54; e.g. `frame:0,29,0` on the main display), is read noise: it never blocks completeness, is not carried forward and is logged once (`ignored noise element`). Previously hosted elements that left the tree legitimately are not "missing" for the attribution rule: the unit the actuator is hiding (`ActuatorPlatform.expectToVanish`, set right before the hide write, cleared when the batch ends, 60 s safety expiry), owners that quit, and owners we assumed hidden. Reasons name the real condition (`N unnamed timeouts, persisted self-positioning groups absent: M, previous-tree absent: K`, plus `no persisted record for pid P` when the record is empty). `HostedEvidence` is unaffected: it compares exact sequences and already expects the vanish.
- **Record pruning, age, noise scoping and reasons (gdu.54)**: (1) On every FULL scan whose app-side extras read of a self-positioning owner succeeded in that same scan (not failed, not budget-missed, not skipped), any persisted group whose identifier the extras no longer list is dropped from the record (log `extras no longer list ...; pruned from the record`) and no longer counts as absent, so a group iStat removed cannot absorb a third-party unnamed timeout. Fast scans never read extras and do not prune. Pruning is also skipped for an owner whose extras list came back empty or contains any child without an identifier (a partly failed read on the 0.3 s cap must not look like "no longer listed"); the trade-off is that an owner with a legitimately identifier-less child is never pruned and falls back to `.incomplete` more often. A prune that empties a record also clears its bundle and refresh timestamp. Matching is by AX identifier; if iStat's extras ever used other identifiers than its hosted groups the record would be pruned empty and attribution would fall back to the previous-tree rule (safe direction: more `.incomplete`). (2) `ScanState.selfPositioningRefreshed` (persisted) is set only by a COMPLETE read (or when a record is first created by an attributed read); a record older than `MenuBarScanner.selfPositioningRecordMaxAge` (600 s) attributes no unnamed timeouts (reason `... self-positioning record older than 600 s (a complete read is required)`, logged once) until the next complete read; named iStat timeouts need no record. (3) When a noise element was dropped (`namedRelevant.count < timedOut.count`) and there are no unnamed timeouts, every missing previously hosted element must still be self-positioning. (4) Reasons for uncovered unnamed timeouts name the previously hosted non-iStat groups missing now (`uncovered: frame:1032,1,24 (owner unknown)`, at most 3). (5) The noise rule "nameless at the left edge" compares with the menu bar strip's `minX` (+-1 pt), not x = 0, so items on a display arranged left of the main one are never noise. Known latency factor, deferred (gdu.54 note e): a verify scan during an iStat streak still takes a full scan (~0.7 s), so hides under load can need ~5 s; a shorter verify scan during streaks is not implemented.
- **Bounded slow reads (gdu.51)**: `LiveAccessibilitySource` remembers the agent groups that did not finish in the previous full read and that the scanner attributed by identity to self-positioning owners (`noteUnresolvedGroups`; `agentSlowGroupTimeout`, 0.3 s): they get ONE short attempt and no retry round (every 5th full read one attempt at the normal timeout), so a full scan during an iStat streak takes ~0.7 s instead of ~2.5 s. `MenuBarScanner.slowOwnerExtrasTimeout` (0.3 s) caps the extras read of an owner whose read failed its retry in the previous scan. The fast path never reads app extras (it attributes from the cache), so self-positioning owners cost it nothing.
- **Exempt keys** (`volatileKeys`): `module:WiFi` and `module:com.apple.menuextra.focusmode` are ignored entirely; the agent's hosted tree drops and re-adds these leftmost modules between reads with no read error (findings-restart-collateral.md, "Scan agreement noise, gdu.46").
- **Duplicates**: a key never appears twice in a result (first by position, a fresh copy beats a stale one; logged with each copy's x, size, stale flag, source and identifier).
- **Exhaustion** (`maxScans` 6 / `deadline` 15 s): the latest usable read (`MenuBarSnapshot.completeness != .incomplete`), preferring one with no on-bar stale item, is returned with `settled == false`; with no complete read the error is thrown as before (`noAgreement`, or `empty`).
- Every scan logs `observe scan N: hostedComplete=... onBarStale=... agree=...` into the app log (`engine: observer: ...`).
- First-launch layout creation (`AppModel.startIfReady`) writes a layout only from a settled read; an unsettled one leaves the layout empty (the engine then adopts new items visible at the end) and logs it.

### LayoutEngine

`LayoutEngine` (actor, `LayoutEngine.swift`) runs the observe -> plan -> act -> verify loop; `EngineState` (`@MainActor @Observable`) is the only thing the UI binds to.

- **Pass**: (1) `observeDetailed()` (two agreeing full scans, see "Observer" below; observation moves nothing, so it runs even while the user is busy); (2) if the mouse is down (`busy`), wait up to 3 s polling every 0.1 s, else skip and retry once (after a wait the observation is repeated); (3) plan with failed keys forced to `canMove = canHide = false` (they become anchors); (4) persist `newItems` into the layout (once per pass) per `newItemPolicy`; (5) act; (6) publish.
- **Two phases**: *membership* is one `applyHiddenBatch` (one agent restart, never called with an empty batch), then re-observe and re-plan; *order* is one `move` at a time, re-planning from the verified snapshot after each. Both continue in the same pass when the post-membership plan is `.order`. At most `maxActionsPerPass` (50) actuator calls per pass; 3 consecutive failed actions end the pass (no chaining; `lastError = .stoppedAfterFailures` only after 3 such passes in a row, see "Robustness"); a membership batch that reports drift ends the pass with `lastError = .batchDrift`, and any other batch failure (e.g. `.mechanismFailed`) with the equally sticky `lastError = .batchFailed(message)` (both cleared only by `clearFailures`/`setLayout`, shown in the Arrange status line; a later successful observe does not clear them); a `.userBusy` batch is handled like a `.userBusy` single action: no key is struck or marked `.failed`, nothing is suppressed, keys it already verified stay in place, and the pass is rescheduled (no retry cap, same as the single-action path) and never chains into drags; at most 2 chained passes. `mbprobe apply` runs the actuator drag-only unless `--allow-fallback`.
- **Observed truth only**: `EngineState.observed` is set solely from an actuator-returned snapshot or a fresh observe, never from the plan. `perItem` is `.inPlace/.pending/.moving/.failed/.unsupported`; `unsupported` (capability skips) does not block `isConverged`, `failed` does.
- **Suppression (flapping guard, gdu.21)**: see "Robustness" below. A key that fails is an anchor for the rest of that pass; the same key failing 3 passes in a row stays `.failed` until `setLayout`, `clearFailures()` (Retry) or its app disappears from the bar. `userBusy` is not a failure and is not suppressed.
- **Fatal errors**: no Accessibility permission or a competing manager (Bartender) sets `lastError`, makes no actuator call and stops the engine until `clearFailures()`.
- **Unsettled observations (gdu.46)**: when the scans never agree but a complete read exists, the pass publishes it (`EngineState.observed`, `observationSettled = false`, `lastError` cleared only when it was an observe error (permission errors still surface); status line "Observing (unsettled)"), logs `observation unsettled; not actuating`, plans nothing, finishes with `PassReport.Outcome.unsettled` and schedules the next pass (`minPassInterval`). Only a settled observation is ever planned on or acted on. The unsettled pass still increments `passSequence` (it must stay aligned with `passesStarted`), so `ArrangeTracker` ignores unsettled states: it suppresses every tracked key's engine status (capsules stay at the pending spinner), judges nothing and pauses its 90 s clock; judging resumes at the next settled state with `passSequence > dropSequence`. The first non-empty scan of a pass is also published at once as a provisional observation when nothing has been observed yet (log `first observation published (provisional, unsettled)`), so the Arrange window has a bar within a scan or two instead of after agreement.
- **Pass latency (gdu.46, reworked by gdu.47)**: `setLayout`/`setShowHiddenSection` supersede the running pass: an observation in progress is cancelled between scans (`ObserveError.superseded`) and the pass ends `.superseded`; a membership batch in flight finishes and the pass then ends `.superseded` (see the gdu.47 bullet), and so does an order-phase pass before its next move; the next pass plans from the new layout and a fresh scan. A plain trigger/poll never cancels an observation, or a slow observation would starve forever (other `supersede: true` requests such as `transient reveal ended` and `agent restarted` cancel only the observation and log their own reason). Logs: `pass started N ms after <reason>` for every request, `pass delayed: <reason> N ms` for any wait over 2 s (previous pass running, user busy). Measured: idle 0 ms; superseding an observation ~0.5 s; during a drag 1.4-5 s (the rest of that drag).
- **Superseded passes, coalescing, fresh snapshots (gdu.47)**: every `setLayout`/`setShowHiddenSection` bumps `layoutGeneration`; a pass remembers the value it started with and ends `PassReport.Outcome.superseded` (log `pass superseded by setLayout`) whenever it differs: (a) during observation (the scan is cancelled; also checked once the observation returns, before planning): nothing planned, no statuses touched, no strikes; (b) while a membership batch is in flight: the actuator finishes THAT batch (its verification stands, against the layout it was planned from), then the engine adopts the batch's snapshot, publishes statuses from a plan for the NEW layout (the batch's keys are `.pending` or `.inPlace`, never `.failed`; no strike, no `batchDrift`) and drops the rest of the stale plan (log `batch finished (...) after the layout changed; not judged against the new layout`); (c) before each order-phase move. The next pass plans from the new layout and a FRESH full scan. A superseded pass still advances `passSequence` (aligned with `passesStarted`). Path (b) publishes honest statuses for the new layout (`.pending`/`.inPlace`, never `.failed`) via `publishObserved`, so `ArrangeTracker` may resolve an EARLIER drop from them (a key `.inPlace` and matching the current layout), but can never fail a drop from a superseded pass; a pass superseded during observation publishes no new statuses. **Coalescing**: `setLayout` publishes and persists the layout at once (stamped revision, gdu.48) but starts its pass after `Config.layoutCoalesce` (300 ms; zero = immediate); another `setLayout` inside the window replaces the pending timer (log `setLayout coalesced`), so only the final layout is planned; `Config.layoutCoalesceMax` (1 s) caps a burst: the pass starts at most that long after the burst's first call even if calls keep coming. A batch that ended because MenuBarAgent was respawned by someone else ends `.agentRestarted`, not `.superseded`. Both drops keep their revision stamps (`passesStartedAtRevision` is the same), the first pass started after them judges BOTH drops' keys against the then-current (final) layout. **Fresh-snapshot rule**: the engine hands the actuator only keys and directions, never a snapshot; `LiveActuator.performBatch` computes `expectations`/`before` from its own scan taken right before the write (log `membership batch: ... pre-write scan`). A batch asking the opposite of a write made < `Config.recentWriteSettle` (1.5 s) ago waits out the remainder and rescans first, so a hide that has not shown up yet cannot make the following show look "already satisfied" (the cause of `not verified: expected membership change, saw unchanged`). An honest "already satisfied" (`batch already satisfied`) still returns `.verified` with `mechanism == nil` and no write.
- **Engine additions ledger (gdu.52)**: each key the pass appends per `newItemPolicy` is recorded as `(revision, key, section, index)` (revision = the one `publishLayout` stamped for that append; last 50 entries kept). `setLayout(_:basedOn:)` re-adds ledger entries newer than `basedOn` that the submitted layout lacks (a same-hide-unit sibling already in the submitted layout decides the section; units stay whole) BEFORE hide-unit normalization and adoption, logging `setLayout merged N engine-added key(s) composed on revision R` once; `basedOn == nil` replaces wholesale.
- **Scheduling**: `requestReconcile()` sets a pending flag; concurrent triggers coalesce into one follow-up pass; pass starts are at least 0.5 s apart. `reconcileOnce()` runs exactly one pass (`mbprobe apply`, tests).
- **Triggers** (`EngineTriggers`, AppKit): app launch/terminate (a burst within 1 s is ONE pass; gdu.56: detected by a pid diff of `NSWorkspace.runningApplications`, driven by KVO (`LiveRunningApps`, covers .accessory/LSUIElement apps) AND by the didLaunch/didTerminate notifications, which AppKit does not reliably post for agent apps; both feed `syncApps()`, which diffs against `known` so one launch/quit = one event whichever path sees it first, while a notification always re-arms the pass so a late-arriving one is not dropped; launch counts for .accessory/.regular only, quit for .accessory/.regular apps that owned an item in the latest scan when `ownerPIDs` is supplied, any such app while ownership is unknown (`AppModel` supplies the owner pids from `EngineState.items`; nil until items exist); the request is `scheduleReconcile(after: 1 s, reason: "app launch/quit")`, trailing-coalesced by the engine; every launch/quit/notification is logged with pid, bundle id and policy), sleep/wake, and a poll (e7t, below); `MenuBarAgentWatcher` (agent respawn) and the app's display-change observer feed the same `scheduleReconcile`. The live `busy` closure is `NSEvent.pressedMouseButtons != 0`. Details: "Robustness".
  - **Poll (e7t)**: every `PollConfig.interval` (10 s) one fast scan is reduced to `BarSignature.value(...).forPoll(...)` (`MenuBarObserver.swift`),
    the SAME rule `AgreedScanObserver` uses for two-scan agreement: ORDER of identified, non-heuristic, non-self-positioning on-bar keys; PRESENCE of other
    on-bar keys; parked set of identified keys. Exempt: volatile modules (WiFi, Focus, "Show Hidden Menu Bar Items"), `heuristic:com.apple.MenuBarAgent` main-menu
    entries, width<=1 items, stale flags, and (poll only) the presence of self-positioning owners' items (iStat's eight items vanish from the fast scan and
    return between polls). The reference is the poll signature the ENGINE publishes with each agreed observation (`PollGate.engineSignature`, serial-stamped), else the last quiet poll's scan
    (the engine's observation omits stale items, so `EngineState.observed` itself cannot be compared): a change after a pass's last observation (an app's item appearing
    after the launch pass observed) is caught by the next poll, and skips never drop it. A difference is CONFIRMED by a second fast scan `confirmDelay` (1 s) later; only
    a second scan with the same new signature requests a pass (`requestReconcile(reason: "poll")`, logged `poll: poll change confirmed ...: <diff>`); a one-scan flicker is
    logged "not confirmed". A signature that already triggered a pass is not re-triggered while the bar keeps reading exactly that signature (loop protection when a pass cannot change what the fast scan sees); any other reading, or a different signature starting a pass, clears the guard, so a recurrence of the same change after the bar was fixed triggers again (steady disagreement costs one extra pass per real change). Fixed 10 s period, no back-off (worst-case
    detection 11 s; the noise fix alone gave 0 passes). Skipped entirely (no scan) while a pass is running/requested/scheduled, the engine sleeps, a transient reveal hold
    is active, `observationSettled == false`, or within 5 s of a user-initiated request (`LayoutEngine.pollGate()`).
    **Cap (gdu.58)**: at most `PollConfig.maxPollPassesPerMinute` (2) poll-triggered passes in any sliding minute (only `reason: "poll"` passes count; launch/quit, wake and user actions are unaffected). A confirmed change that would exceed it triggers nothing, logs once `poll: suppressed for 5 min — flapping keys: <keys>` (symmetric difference of the two most recent differing signatures) and opens a `PollConfig.suppressFor` (5 min) window: the poll keeps scanning but triggers nothing, even for a genuine single change (launch/quit triggers and user actions still work); afterwards it logs `poll: suppression ended, resuming` and the first change triggers as usual. Published as `EngineState.pollSuppression` (`PollSuppression{until, keys}`, set via `LayoutEngine.setPollSuppression`) and shown in the Arrange status line as `Poll paused 5 min: <names> flapping`; status line only, not `lastError`, not `.failed`, overflow panel unaffected.
- **UI binds to**: `observed`, `layout`, `perItem`, `inFlight`, `lastError`, `isConverged`, `lastPassAt`, `passCount`; it changes the bar only via `setLayout` / `setShowHiddenSection`.

### Robustness: launches, respawns, display changes, sleep (gdu.21)
Every event becomes a (delayed) `LayoutEngine.requestReconcile`; none of them acts on a read that is not trustworthy.

- **Coalescing**: `scheduleReconcile(after:reason:)` keeps ONE pending request per reason; a new call with the same reason replaces it. App launch/quit
  uses reason `app launch/quit` with a 1 s trailing window (a burst of launches/quits is one pass; a returning app's items go back to their slot by the
  normal order planning and keep their hidden state, which lives in the Control Center store per app). Display changes use `display change` (1 s), wake
  `wake` (3 s), agent respawn `agent restarted` (2 s, supersedes an observation in progress).
- **`MenuBarAgentWatcher`** (`SommelierCore`, main actor): compares the pid of `com.apple.MenuBarAgent` with the last known one on NSWorkspace
  launch/terminate notifications for that bundle id and on a 2 s poll (live, the notification does not arrive for the agent, so the poll is the
  detector; absence between terminate and launch is not a change). On a change it logs `agent restarted: pid A -> B` and the app runs
  `LivePlatform.invalidateAgentState()` (scanner: last hosted tree, stale carry-over, last complete layout, strip, unverified counters; kept: the
  assumed-hidden records, because the store still says hidden, per-app caches and seen-hosted names; the AX element cache already drops the old agent's
  elements on a pid change) and `LayoutEngine.agentRestarted()`.
- **Not-ready guard**: `agentRestarted` sets `notReadyUntil = now + 2 s` and drops transient reveal holds. A pass whose settled observation is
  obtained inside that window logs `agent restarted moments ago; not acting on this observation` and ends as `.unsettled` (nothing published,
  planned or done); the delayed reconcile follows. Independent of the watcher: an EMPTY on-bar list is `ObserveError.empty` (never "everything is
  hidden"), an incomplete hosted read can never be an observation (`hostedReadComplete == false` is not returned as a read), and an unsettled read
  is published but never planned on; tests: `EngineRobustnessTests`. Live, a pass that spanned a respawn saw `hostedComplete=false`, two complete
  reads with 4 stale on-bar items, and acted only after two complete agreeing reads, with no action.
- **Respawn accounting and ownership (corrective pass)**:
  - A hide/show batch that went through an agent respawn (`MenuBarActuator.lastBatchRespawned`; the hide fallback ignores `allowFallback`) strikes its
    FAILED keys out at once (`fullStrike`): at most ONE respawn per key per layout change; suppressed until `setLayout`/Retry, logged once. Drags
    keep the 3-strike rule (bounded, no fallback). The follow-up pass scheduled in `finish()` counts against `maxChainedPasses` (2); a membership
    batch that reports failure never chains anyway (`endAfterBatchDrift`).
  - Our own respawns: `LivePlatform.restartAgent` marks itself in progress and remembers the resulting pid (`isOwnAgentPID`). The watcher
    (`busy:` / `isExpected:`) reports nothing while it runs and absorbs the new pid afterwards (`agent restarted by Sommelier (expected)`): no state
    invalidation mid-action, no extra reconcile.
  - Passes spanning a foreign respawn: the engine records the agent pid at pass start (`agentPID`) and checks it after the observation and in
    `adopt()`. A different, non-own pid discards the observation (nothing published, planned or actuated), logs `agent restarted during the pass`,
    opens the not-ready window and schedules the reconcile; the pass ends as `PassReport.Outcome.agentRestarted`. After our own respawn the pass
    re-bases on the new pid and continues.
  - `MenuBarAgentWatcher.start()` keeps the last KNOWN pid across `stop()` (Bartender pause, permission loss) and compares at once, so a respawn
    during the pause is reported on resume.
- **Sleep/wake**: `EngineTriggers` calls `willSleep()` (no new pass starts, pending requests and delayed reconciles are dropped; a running pass ends
  after the action in flight, re-checked before every move) and `didWake()` (reconcile 3 s later). `triggers.start()` clears a sleep flag left by a
  missed wake.
- **Conflicting manager (gdu.35)**: `AppModel` calls `engine.setConflict(who)` (nonisolated, lock-protected) when Bartender is detected; a pass already running checks it before the membership batch and before every order move, issues no further actuator call and ends `.paused` (no failure, strike or suppression), no new pass starts until `setConflict(nil)` on resume.
- **Display changes** (`AppModel`, `NSApplication.didChangeScreenParametersNotification`): `platform.invalidateStrip()` (the strip is recomputed from
  the next agent read), the open overflow panel is re-anchored to the status item's screen after 0.4 s (`OverflowPanelController.reposition`; its
  frame comes from `OverflowPlacement.panelFrame` on the screen under the item), and ONE reconcile after 1 s (bursts of notifications collapse).
- **New-item notice**: unknown items placed by `newItemPolicy` log `New item: X placed in Visible|Hidden` and set `EngineState.newItemNotice`
  for 10 s; the Arrange window prefixes its status line with it. No system notification.
- **Flapping guard**: `strikes[key]` counts passes in a row in which the key failed (one strike per pass; a pass in which it did not fail breaks the
  streak). Below 3 the key is retried by the next pass (a failing pass schedules one follow-up, bounded by the strikes); at 3 it is logged once
  (`<key> failed 3 passes in a row ...; marked failed until the layout changes or Retry`), stays `.failed` and an anchor. A deterministic refusal
  (capability forbids) goes straight to the limit. The whole engine is NOT stopped by one bad key: a pass ends after 3 consecutive failed actions,
  and only 3 such passes in a row (no action succeeded in between) set `lastError = .stoppedAfterFailures(3)`, cleared by `clearFailures`/`setLayout`.

## (e) What cannot be done, and how the UI shows it

| Limit | Evidence | UI |
|---|---|---|
| Module items (Wi-Fi, Battery, clock, Control Center, Siri): cannot be dragged, cannot be placed right of Control Center/clock; hidden only in System Settings > Menu Bar | findings-positioning C3 (placement limit, measured); no-drag is a self-imposed rule (`ItemResolver.protected`, mbprobe refuses), untested by design since we never drag Control Center/clock; store refuses `module:` (self-imposed guard) | lock icon; `Capability.canMove=false, canHide=false`, reason tooltip, "Open Settings" link |
| Third-party item cannot go right of Control Center | positioning C3 | drop target clamps; `.rightmost` means just left of Control Center |
| App without a Control Center tracked entry cannot be hidden | visibility A7/A8 | `canHide=false` + reason "not tracked by Control Center"; entry is auto-created ~0.2-0.3 s after launch, hand-created entries only with the exact system shape (gdu.24, findings-untracked-hide.md) |
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

* **sommelier-gdu.24** (done): see findings-untracked-hide.md; follow-up: implement the entry-creation recipe for ad-hoc apps, prove the signed-app form first.
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
- Left click is configurable (Settings > General > "Left click", `revealMode`): the **overflow panel** (default, `panel`) or **show hidden
  items in the menu bar** (`inline`); right click shows the menu (rebuilt per open). Our own item is never scanned.
- **"Show the rest", two modes (gdu.15).** Mode 2 is the overflow panel (items stay parked, see "Overflow panel"). Mode 1 is the inline
  reveal, driven by two engine flags: `LayoutEngine.setReveal(hidden:alwaysHidden:)` sets `showHiddenSection` (hidden section) and
  `showAlwaysHidden` (always-hidden section too; option-click). The `Reconciler` treats the flagged sections as wanted on the bar, appended
  right of the visible section in layout order (hidden first, then always-hidden); hide units stay whole (an app with an always-hidden item
  stays hidden unless `showAlwaysHidden`). A reveal and its re-hide are NORMAL passes (live writes, verification, no respawn, gdu.55).
  `EngineState.revealedObserved` is the OBSERVED state, written only when a pass ends (converged/incomplete) from the bar it observed:
  true when a reveal is requested and at least one revealed item is on the bar (a partial reveal counts as shown; the failed items keep
  their own `perItem` status), and with nothing requested it stays true until the re-hide has landed. The request alone never changes the
  icon: `StatusItemController` shows `wineglass.fill` when `revealedObserved`, else `wineglass`.
  `RevealController` (SommelierCore, testable) turns clicks into requests: a click while requested or revealed re-hides at once, option-click
  also sets `showAlwaysHidden`, clicks within 300 ms of the previous accepted click are ignored, and it logs click -> converged time.
  `RevealAutoRehide` (app) runs while a reveal is requested: re-hide after `autoRehideSeconds` (0 = never) without pointer activity over
  the menu bar strip (the clock starts when the reveal is observed), or 0.6 s after the menu of a clicked menu bar item closed (global
  `NSEvent` monitors: leftMouseDown over the strip arms it and suspends the idle clock; the next click below the strip or Escape is the close; a close
  never seen ends after 20 s); a reveal that never converges is withdrawn after 20 s (log line plus `EngineState.revealNotice`, shown in the
  Arrange status line as "Reveal withdrawn: N items could not be shown"). Untracked units: the membership batch is all-or-nothing (`LiveActuator`
  refuses it when one key has no Control Center entry), so the planner (`Reconciler.plan`, the `gdu.15` block in the unit loop) drops a unit that is
  pulled onto the bar only by a reveal when one of its parked keys has `canHide == false`, with the skip reason "cannot be shown: not tracked by Control
  Center" (neutral `.unsupported` status). The other units show; the reveal counts as converged and `revealedObserved` is true (partial = shown).
  `LiveActuator`'s refusal stays as the belt-and-braces guard.
- Settings layout convention (gdu.59): a `TabView` of `Form`s with `.formStyle(.grouped)` (labels leading, controls trailing, captions and footnotes in secondary style); one shared width (540 pt) and a per-tab height chosen in `SettingsView.height`, so the window fits each pane with no dead band. New controls go into a Form row, never a fixed-width HStack.
- Bartender launch stops triggers and pauses; its termination resumes. `permissionDenied` stops triggers and shows onboarding;
  re-grant calls `clearFailures()` and restarts.

### System overflow (gdu.45)
When the bar is full macOS (MenuBarAgent) hosts a chevron ("<<") and pushes the leftmost items behind it. They stay in the
hosted tree, so `isOnMenuBar` keeps meaning "on the bar per the agent", but they are not drawn and a drag on them is a no-op.
- ONE rule (gdu.69), `SystemOverflowRule.isOverflowed(frame, chevron:, hosted:)` in MenuBarItem.swift, used by the scanner's
  flag (`SystemOverflow.mark`/`indices`), `ActuationVerifier.overflowed` and `OverflowProbe.isStacked` (gdu.65). With a FRESH
  chevron (`isOverflowChevron`, found structurally, see docs/findings-drag.md) in the same read, a fresh on-bar frame is
  overflowed when it lies left of the chevron's minX, or its centre is on the chevron, or it is stacked on another hosted frame
  (centres within 2 pt) AND starts left of the chevron's maxX (the clipped pile extends past the chevron's minX live). Identical
  frames far right of the chevron are chance, not overflow (findings-drag incident). No chevron, or a stale one, flags nothing.
  Before gdu.69 the scanner flagged only items ordered before the chevron while the verifier also named stacked pairs and the
  probe flagged stacked frames anywhere; worse, the scan often had NO chevron item at all: the hosted-to-candidate frame join
  (`MenuBarScanner` `pass(.frameAmbiguous)`) paired the chevron element with an app item whose frame overlapped it (Script
  Menu), so nothing was flagged and the planner kept planning moves of overflowed items. Chevron elements are now never joined.
  The verifier keeps its pair-local identical-frame pre-drag guard, which never feeds the flag. `ObservedOrder.systemOverflow` /
  `overflowChevron`, `ItemInfo.systemOverflow` and `ItemStatus.notFitting` carry the flag to the planner and UI.
- Engine (gdu.69): an actuator refusal whose error `isOverflowRefusal` (`mechanismFailed` containing "is in the menu bar
  overflow area", raised before any drag) is a skip, not a failure: no strike (`markFailed`), no `consecutiveFailures`; the key is
  remembered for the pass (`overflowRefused`) and its moves are dropped from the plan (skip `Reconciler.overflowSkipReason`).
  Statuses: a key flagged `systemOverflow` stays `.notFitting` (never red, never overridden by the skip).
- Rule: Sommelier orders the drawn bar; macOS decides what overflows (it depends on total width), so a layout's order across the
  overflow boundary is not a request Sommelier can act on. `Reconciler.plan` drops the overflowed keys and the chevron from
  `desired` and `base` before the order planning: no drawn key is ever anchored or reported because of them, whatever the layout
  lists (unknown, pulled-in, normalized or churned). Only an overflowed key the layout places differently relative to the drawn
  keys gets one skip "in the system overflow area; macOS decides what fits" (gdu.69; agreeing layouts stay silent). No move has an
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
  after it (`passSequence > passesStartedAtRevision`, where the ENGINE stamps every layout it publishes, gdu.48: `EngineState.layoutRevision`
  increments on `start`, `setLayout` and when a pass appends new items, and `passesStartedAtRevision` is `passesStarted` at that moment;
  `setLayout` returns the stamp as `LayoutRevision`, the tracker entry waits un-judged (`awaitingStamp`) until it arrives, so a pass that
  starts right after publication but before any UI tick counts, and one already running at publication never does); older
  statuses are suppressed and shown as "⟳", so an old failure never appears on a new drop. After 90 s without a match the capsule shows
  the timeout "⚠", cleared by a later match. Without a trustworthy observation (none yet, or `lastError` is an observe failure) the
  Visible strip shows "No observation yet - ..." and no capsules, and drops that touch Visible are refused. Capabilities come only from
  `ItemInfo`; a key without one is unknown and allowed (the engine decides). (2) A badge is "✓" only
  when the engine status says in place; failed -> "⚠" with the error text as tooltip, `.unsupported` -> "⊘" with the reason,
  `.notFitting` -> the does-not-fit marker; items whose app is not running carry no badge and sit in a collapsed "Not running (N)"
  group. Before the first observation rows make no claims. (3) Hidden and Always hidden follow the LAYOUT order and reorder
  optimistically, because their order is our own data (there is no observation to wait for; only the membership change itself is
  verified, shown as a ghost in the destination strip and "⟳" on the capsule still on the bar). (4) The layout the window submits
  is shown at once (`PendingLayout`) so consecutive drops build on each other; everything else is the engine's state. The pending
  copy is compared by REVISION, never by equality: it is dropped once every submission has returned its revision and
  `state.layoutRevision >=` the latest. Rebase rule: while pending, `PendingLayout.effective(over: state.layout)` is the base of every
  further drop and appends any key the engine added that the pending copy lacks, so a stale pending copy is never resubmitted over the
  engine's additions (no stuck "⟳"). Merge rule (gdu.52): the window submits `setLayout(l, basedOn: state.layoutRevision)` (the revision `l` was composed on); the engine re-adds every key IT appended since that revision (additions ledger, see Engine) that `l` does not place, at its engine-chosen section/index, so a drop never discards a just-appended item (no second "New item" notice); a key `l` already places keeps the user's placement; with no base revision (`mbprobe apply`, `AppModel`) `l` replaces the layout wholesale. (5) Failure clearing: when a settled observation finds a `.failed` key's placement
  realized and the plan does not touch it, the engine clears the failure (log `cleared failure for X: now in place`; a failure recorded
  in the same pass stays until a later pass), so its badge and the "N failed" status line clear and the tracker's timeout "⚠" resolves;
  `.unsupported` is derived afresh every pass. (6) Capabilities are computed on demand from `state.items` (not only while the window
  is open), so the `SOMMELIER_ARRANGE_MOVE` hook resolves them exactly like a UI drop.
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
  width of parked items; stale reads keep their previous info; vanished items are dropped).
- `OverflowEntries.make` (pure) turns `layout.hidden` + `items` into entries in layout order; keys with no entry in `items` (not in the
  latest scan; a stale read keeps its last info until a read omits it) are skipped. `OverflowPlacement.panelFrame` (pure) right-aligns the panel to the status item under the bar.
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
   than before the write (`hostedBarCount`); without a usable complete baseline (`baselineAttempts` tries) the activator does not reveal at all and presses in place (left) / refuses (right). A cancellation during that baseline read returns `.cancelled` (nothing was written; the hold is released).
   The reveal is per unit (app): siblings appear too while the menu is open.
   **Locate strategy (d5c)**, cheapest first: (1) `locateCached`: the element handle from the newest full scan this process ran
   (`LivePlatform.lastFullScan`, at most 120 s old); one element read re-checks owner pid, identifier (else description), frame and that the cached
   on-bar state still agrees with the live frame (ms); (2) `locateByOwner`: re-read only the owner's `AXExtrasMenuBar` and take the single
   element with that identity (tens of ms); (3) the full `scan()` (0.6-1.8 s), the only source of `.notFound` / `.notRunning`, so failure feedback is
   unchanged. Any identity or consistency miss falls to the next source. "Drawn" no longer needs the slow full hosted read: a PARKED target lands on its
   settled frame alone; a live-hidden target (stale on-bar frame) lands when the agent's top-level group count (`hostedGroupCount`, one shallow read) rises
   above its pre-write value, plus the settled frame. The pre-write full hosted baseline (re-hide evidence only) is time-boxed to `baselineBudget`
   (300 ms); when it is skipped the reveal proceeds, the activator still writes the re-hide itself, and only the of7 assumed-hidden record is skipped (the engine's next pass records it once the readback shows the unit hidden); cancelling the baseline read does not stop the underlying hosted read, which runs to its own end. Timings: docs/testing.md "Reveal latency before/after".
2. **`axPressParked` (fallback, left click only)**: `AXUIElementPerformAction(kAXPressAction)` on the app-side element while it stays parked.
   Used when live hide/show is unavailable (no app-group entitlement), the item has no Control Center entry, the live write throws, or the
   reveal does not land within 1.5 s. CAVEAT: the menu/popover appears at an unrelated place (the item's frame is the parked frame at
   y ~1188: left screen edge below the bar, or mid-screen; docs/findings-visibility.md). The AX call may return -25204 although the menu
   opened, so a press error counts as failure only if no menu/popover child appeared within 1.5 s. A right click cannot be forwarded this way
   (`failed(.unavailable)`).
3. **`axPressOverflow`**: an item macOS moved into its own overflow (kind `.notFitting`) is on the bar but not drawn: AXPress, no reveal.
4. **Revealed into the system overflow (gdu.65)**: on a full bar the unit can land behind MenuBarAgent's "Show Hidden Menu Bar Items" chevron: the group count rises and the frame settles (stacked, e.g. x 772), but nothing is drawn and a click at the frame centre hits the chevron. After the drawn check `ItemActivator` asks the platform for `overflowProbe()` (top-level agent reads, ms: the chevron = direct AXButton child of the agent window without identifier/title, the other direct children's frames, `expanded` = the agent's AXMenuBar starts left of the chevron) and `OverflowProbe.isStacked(frame)`: true when there is a chevron, the strip is not expanded, and the frame is left of the chevron, or its centre lies on the chevron, or another hosted group has the same centre x (within 2 pt). Never click a stacked frame. Path (a): click the chevron (70 ms hold), poll the target's own AX frame until it is real (settled, unstacked, off the chevron, equal on two polls; app-side frames follow the expanded strip, e.g. 772 -> 307, ~106 ms), click it there, and after the menu closes (or fails to open) click the chevron again until `expanded` is false (Escape does NOT close the strip; note `overflowStripStillExpanded` if two clicks fail). Path (b): the item does not show a real frame within `overflowExpandTimeout` (1 s): collapse, re-hide, `.failed(.unavailable("behind the system overflow chevron; make room in the bar"))`. Log lines `phase overflow: ...` with `t=<ms>`.
A drawn item (Control Center says allowed) is simply clicked (`barClick`).

Menu close: a `CloseMonitoring` source (app: global `NSEvent` monitor for mouse-up and Escape, installed only during an activation;
`mbprobe`: a listen-only CGEvent tap), OR the menu/popover child (counted against its count before the click, because some apps keep an empty
zero-sized `AXMenu` child) disappearing, polled every 250 ms; then a 300 ms settle. An outside mouse-up is believed only if the menu is gone
(a popover survives a click inside it); Escape is always believed. Menu detection also counts the app's AX windows against their count before the click (popovers are windows), so any new app window is taken for the menu. Hard cap 60 s: at the cap the activator posts an Escape and waits up to 2 s (`capEscapeGrace`) for the menu to vanish before re-hiding; if it is still open it re-hides anyway and the result `note` is `menuStillOpenAtCap` (re-hiding under an open menu was seen live with Moom). The re-hide is written once; a throwing write still releases
the hold and the result carries `rehideFailed` (the engine's next pass hides it); the activator never retries.

Engine hold: while a unit is held the engine hides `ObservedOrder` entries of that unit from the planner (it neither hides nor orders them), shows
them as `.pending` in `EngineState.perItem`, and auto-expires the hold after the timeout (65 s). `endTransientReveal` requests a reconcile.
KNOWN LIMITATION (bead filed): for items without an AX identifier/description (Tot, Yoink, Moom) the scanner cannot see a live hide, so after
the hold ends the next pass sees the item "on the bar", plans a hide and the live verification fails, which used to fall back to ONE agent respawn
(`live verify failed ... falling back to respawn`, ~4.5 s flash; since gdu.55 an unconfirmed live hide is `liveUnverified`, no respawn). The item itself is hidden again as soon as the live write lands.
Latency: the user-felt metric is panel click -> menu visible (activation starts on mouse-UP); it is 0.55-3 s in practice (locating scan 0.2-1.8 s,
hosted reads, live show 60-300 ms), so the 700 ms target is met only for the fastest reveals; the click -> menu part is 22-130 ms. Landing needs a
settled frame (y 0...5, identical on two polls) AND one more hosted item than before the write (baseline read after the hold; an incomplete read
means AXPress, never a believed stale frame). A click that opens no menu within 1.5 s is `.failed(.noMenu)` (re-hide and release still happen);
a cancelled task re-hides and releases too.
Debug: `SOMMELIER_ACTIVATE="<storeKey>[|right]"` (3 s after launch, result in `build/sommelier.log`); `mbprobe activate <key> [--right]
[--ax-press] [--escape-after S]`.

## Spacing (gdu.20)
`SpacingSettings` (Core) reads/writes `NSStatusItemSpacing` and `NSStatusItemSelectionPadding` in the global domain, current user, current host (same store as `defaults -currentHost write -globalDomain`), clamped to 0...24, behind an injectable backend for tests. Measured on macOS 27: a change applies to each app when it relaunches, not to running apps, and no MenuBarAgent restart is needed (details in `docs/findings-spacing.md`). The Settings Spacing tab writes on slider release, offers "Reset to system default" (removes both keys) and never restarts the agent itself (gdu.55). `mbprobe spacing get|set|reset` is the CLI surface.

### Tracked entry resolution (gdu.68)
Helper processes (Hazel Helper, HoudahSpot Helper, Fantastical Helper, Keyboard Maestro Engine, Little Snitch Agent) have no Control Center entry of their own;
they are listed in their parent app's `menuItemLocations`, and the parent's `isAllowed` adds/removes the helper's hosted element (docs/testing.md "Helper keys hide through the parent entry").
`TrackedEntryResolver` maps an item's owner key / bundle id / heuristic bundle id to the governing entry: an own entry wins, else the single non-Apple entry that lists the id
(ambiguous = none). `CapabilityRules` (via `EngineFactory.makeCapabilityRules(resolver:)`) and `ActuatorPlatform.trackedKey(for:)` share it, so the planner and the actuator agree and the
actuator's per-entry grouping (one write, all members verified, conflicting requests refused) covers helper + parent. Not done: `ItemKey.hideUnit` is still the owner key, so Layout/Reconciler/Arrange do not yet
treat a helper and its parent's own item as ONE unit (the actuator refuses a batch that asks them to differ). Untracked non-Apple apps (no entry anywhere) remain unhideable: the gdu.24 entry-creation recipe is not built.
