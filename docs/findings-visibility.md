# Findings: hiding / showing menu bar items (bead sommelier-gdu.6)

Host: macOS 27.0.1, 1920x1200, 2026-11-03. Bartender 7 quit for experiments A/B, running for C, relaunched at the end.
Tools: `mbprobe cc-allowed`, `set-visible`, `press`, `agent-restart`, `list`; `make dummy` (ie.boboco.mbdummy, items DA/DB).
Evidence: `docs/evidence/gdu6-*` (byte copies `gdu6-cc-before.plist`, `gdu6-agent-before.plist`, baseline `gdu6-baseline.json`,
logs `gdu6-A*.txt`, `gdu6-B*.txt`, `gdu6-C-press.txt`). "Observed" = repeated `mbprobe list` scans (1-4 s each).

## `trackedApplications` blob format
`~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist` (mode 0600, binary plist).
Top-level keys: `trackedApplications` (Data), `remoteLiveActivityApplications`, `showSpotlight`, `showTimeMachine`.
The `trackedApplications` Data is itself a binary plist: a flat ARRAY of alternating key/value dictionaries (a Swift
`Dictionary<Location, Entry>` Codable-encoded as an array), 146 elements = 73 apps:
- key (even index): `{bundle: {_0: "<bundle id>"}}` or `{adhocBinary: {_0: {relative: "file:///path/to/binary"}}}`
- value (odd index): `{location: <same as key>, menuItemLocations: [<location>, ...], isAllowed: Bool}`
`menuItemLocations` is order-insensitive (the system reshuffles it on rewrite; harmless). The dummy's key is
`bundle ie.boboco.mbdummy` with `menuItemLocations = [adhocBinary <path of MBDummy>]`; the system creates this entry itself
when a new app first shows an item (as `isAllowed=true`).
Implementation: `SommelierCore/ControlCenterTrackedAppsStore` (decode, `isAllowed`, `setAllowed`, atomic write keeping mode,
in-memory backup, unknown keys refused without `create`, `module:` and `com.apple.*` refused). Re-encoding the blob with
`PropertyListSerialization` is accepted by the system (changed keys only differ; unit tests round-trip the evidence file).

## Experiments
| # | Subject | Write | Trigger | Observed | Frame after | Restores? |
|---|---|---|---|---|---|---|
| A1 | MBDummy DA+DB visible | `cc-allowed set ie.boboco.mbdummy 0` | none (15 s watch, 3 scans) | no change | DA x=1078/DB x=1048, y=3 (bar) | n/a |
| A2 | same | (same write) | `killall MenuBarAgent` | applies; both dummy items parked, bar back in ~1-12 s (poll noisy, first hosted AX read ~1 s) | x=-1, y=1203 (parked) | yes |
| A3 | parked dummy | `set ... 1` | none, 10 s | no change (still parked) | x=-1,y=1203 | |
| A3b | parked dummy | (same) | kill system ControlCenter (+ the pid respawns in <1 s) | no change | still parked | |
| A4 | parked dummy | `set ... 1` | `killall MenuBarAgent` | applies; items return in their OLD slots | DB 1046, DA 1076 (before 1048/1078, same order) | yes |
| A5 | visible dummy | `set ... 0` | kill system ControlCenter only | no change in 12 s | still visible | |
| A6 | visible dummy | (same write) | `killall MenuBarAgent` | applies (~1 s to first AX read) | parked x=-1,y=1203 | yes (A4) |
| A7/A8 | dummy entry deleted from plist | `set ... 0 --create` (bundle entry, menuItemLocations = bundle) | agent restart (also variant with ControlCenter restarted first) | NOT honored: system rewrote an entry for the dummy with `isAllowed=true` and adhocBinary menuItemLocations; items stayed visible | on bar | |
| B1 | dummy, no removalAllowed | `set-visible ... Dummy-A 0` (CFPreferences, any host) | none 10 s; then `killall MenuBarAgent` | no change; no change | on bar | |
| B1c | dummy | key pre-written | relaunch dummy | DA gone entirely (absent from AX, not even parked); app migrated key to `NSStatusItem VisibleCC Dummy-A = 0` | absent | |
| B2 | dummy, DA hidden by B1c | `defaults write ... "NSStatusItem VisibleCC Dummy-A" -bool true` then false | none, 8 s each | no live effect | absent | |
| B3 | same | VisibleCC=1 | relaunch | DA back at its slot (1076) | on bar | yes |
| B4 | dummy `--removal-allowed` | Visible Dummy-A = 0 | none 8 s; `killall MenuBarAgent` | no change; no change | on bar | |
| B5 | `--removal-allowed` | Visible=0 pre-written | relaunch | DA absent, key migrated to VisibleCC | absent | same as B1c |
| C | Yoink, Tot (Bartender-hidden, parked at x=2,y=1204) | none | `AXUIElementPerformAction(kAXPressAction)` on app-side AXMenuExtra | works. Yoink: AXMenu child at (-5,34) (left screen edge, below bar), AX call returned -25204 (cannotComplete) on some runs although the menu opened. Tot: AXPopover at (710,30), AXError 0 in ~75 ms. A CGEvent Escape closed both | menu/popover anchored away from the bar (Yoink at screen left edge, Tot at x~710 with its arrow near x~720) | n/a |
| D | separator trick | not run (A succeeded) | | | | |

Notes: (1) `mbprobe agent-restart` printed `recovered=false` in several runs only because the hosted AX count is noisy or the
count legitimately dropped (hidden items are not hosted); the items were observed correctly by scan. (2) Entry survives
`isAllowed` edits while system ControlCenter keeps its in-memory copy: no clobbering was seen for edits to existing entries.
(3) Do NOT `killall ControlCenter`: Elgato Control Center (bundle com.corsair.ControlCenter) is also named "ControlCenter"
and was killed (not respawned) by my first attempt; I relaunched it. `--restart-cc` now uses an anchored `pkill -f` on the system path.
(4) Screenshots taken during C leaked the content of Tot's popover; they were deleted, not kept as evidence.

## Conclusion
- Preference-driven hide/show LIVE: no. The `isAllowed` flag is read by MenuBarAgent only at launch; there is no live reload
  (15 s watch), and restarting only the system ControlCenter does not apply it.
- Mechanism that works: edit `isAllowed` in the Control Center plist blob (`ControlCenterTrackedAppsStore`, `mbprobe cc-allowed set`),
  then `killall MenuBarAgent` (same trigger and cost as repositioning: ~1-3 s, 1-2 s bar blank/flash, no logout, other items keep
  their slots; shown items return to their previous slot). Hidden items are parked at (-1..3, 1188..1204), keep their order values.
  Batch hide, show and reorder writes into ONE agent restart.
- removalAllowed is irrelevant. Legacy `NSStatusItem Visible <autosave>` writes (any host) are not live and are not honored
  by MenuBarAgent; they only act when the owning app relaunches (app-side, the key becomes `VisibleCC`, item removed from
  the bar entirely, not parked, apps that create the item with their own logic may differ). Not a usable mechanism.
- Creating entries for apps the system has not registered is not honored; only hide apps that already have an entry.
- AXPress works on parked items: the menu/popover opens, but at an unrelated location (Yoink: screen-left strip below the bar;
  Tot: x~710), so for the overflow panel we can trigger the real item's UI without un-hiding it, but cannot anchor it where
  we want; Escape via CGEvent dismisses. The AX return can be -25204 even when the menu opened (treat via observing children).

**Recommendation for T07:** hide/show = `ControlCenterTrackedAppsStore.setAllowed` + one `killall MenuBarAgent` (batched with order
writes); verify afterwards with the scanner (parked vs on bar). Cost: agent process restart, ~2-3 s typical, bar flash.

## End state
Bartender 7 running; MBDummy stopped, its defaults domain deleted (it was empty before); Control Center plist byte-identical to
`gdu6-cc-before.plist` (restored, system ControlCenter and MenuBarAgent restarted); agent plist byte-identical to
`gdu6-agent-before.plist`; Elgato Control Center relaunched; on-bar signature equals `gdu6-baseline.json` (24-25 items;
only difference is WiFi Signal text 65% vs 64%).

## Per-app granularity (observed during gdu.12 live check)
Control Center's `isAllowed` applies per app (tracked key `ie.boboco.mbdummy`), not per status item: hiding Dummy-A also parked Dummy-B (one `applyHiddenBatch`, agent restart ~1-15 s, 19 s end to end for the pass) and showing either one shows both.
A layout that asks for one item of an app hidden and another visible can therefore never converge; the model treats items of one tracked app as a hide unit: see "Hide unit" in docs/architecture.md (Layout model, Reconciler; bead gdu.31).
