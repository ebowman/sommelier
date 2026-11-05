# Findings: hiding apps that have no Control Center tracked entry (bead sommelier-gdu.24)

Host: macOS 27.0.1, 2026-11-05. Subject: MBDummy only (`ie.boboco.mbdummy`, ad-hoc signed, items Dummy-A/Dummy-B). Bartender 7 was quit for the whole run
and relaunched afterwards. MenuBarAgent was NOT restarted (pid 21399 constant). All writes went through cfprefsd with an entitled
binary (`com.apple.security.application-groups = group.com.apple.controlcenter`), domain `group.com.apple.controlcenter`, key `trackedApplications`
(the live path of findings-live-trigger.md). Readback = `CFPreferencesCopyAppValue` from the same entitled binary, polled every 200 ms.
Tools (scratchpad, not in repo): `cct` (dump/remove/restore/create/set/poll, MBDummy only) and `rb` (restore the whole blob from a backup).

## Answers
1. **Does the system create the entry for a freshly launched status-item app? YES, automatically, about 0.2-0.3 s after launch**, with `isAllowed = true`.
   * Start: MBDummy entry present from earlier sessions (`isAllowed=1`, adhocBinary location, recorded and removed with the entitled writer; blob 76 -> 75 entries, readback `ABSENT`).
   * Run 1 (`make dummy`, poll 30 s): `01:38:41.685 ABSENT`; `make dummy` finished (`open` returned) at 01:38:48.94; `01:38:49.255 PRESENT isAllowed=1` = +0.32 s after `open` returned.
   * Run 2 (dummy stopped, entry removed, `open build/MBDummy.app` at 01:39:31.95): `01:39:32.109 PRESENT isAllowed=1` = +0.16 s.
   * Then stable for the rest of both 30 s windows (no further change). Entry created: key `{bundle:{_0:"ie.boboco.mbdummy"}}`, value
     ```
     {isAllowed: true,
      location: {bundle: {_0: "ie.boboco.mbdummy"}},
      menuItemLocations: [{adhocBinary: {_0: {relative: "file:///.../build/MBDummy.app/Contents/MacOS/MBDummy"}}}]}
     ```
     (the same shape as every other entry; for ad-hoc signed apps `menuItemLocations` is the `adhocBinary` of the executable that registered the status item, for signed apps the existing entries show `bundle` ids).
   * The entry is created at launch / first status-item registration, not at agent restart. Removing the entry while the app keeps running does NOT recreate it
     (12 s poll: stays `ABSENT`; the app still on the bar).
2. **Can the entitled writer create an entry that the system keeps and honours? YES, but only with the exact shape the system itself would write.**
   * Adhoc shape above with `isAllowed=false`, written while the dummy ran with no entry: `Preferences: changed` in the MenuBarAgent log 13 ms after the write
     (01:40:39.007), `mbprobe list` reported both items `hidden=notHosted`, readback stayed `isAllowed=0` for 14 s (poll) and was still 0 after ~65 s and in the plist file; relaunching the app with that entry
     present parked both items (`hidden=parkedFrame`, x=-1) and the entry stayed 0 for 25 s.
   * Pre-launch creation (dummy stopped, entry created with `isAllowed=false`, then launch) with the adhoc shape: honoured, stayed 0 (8 readbacks over 12 s), items parked.
   * **Wrong shape is overwritten within ~0.25 s of the app launching**, with `isAllowed=true` and the system's own `menuItemLocations`:
     * `location: bundle` in `menuItemLocations` for the ad-hoc dummy (`01:44:43.111` launch, `01:44:43.366` readback `isAllowed=1`);
     * a wrong `adhocBinary` path (`.../nowhere/Fake.app/...`): readback `isAllowed=1` with the real path from the first poll on.
     The system re-validates `menuItemLocations` against the launching executable and replaces a non-matching entry (this is also the A7/A8 overwrite).
   * **HAZARD: an entry without `menuItemLocations` (only `isAllowed` + `location`) makes the system DISCARD THE WHOLE BLOB.** After launching the dummy with such an entry,
     the blob dropped from 76 entries to 1 (only the dummy, `isAllowed=1`; plist file 522 bytes) within 1 s, reproduced twice (once by accident, once on purpose). Every other app's
     `isAllowed` (1Password, Moom, Yoink, ...) was lost; items hidden by those entries would reappear on the next agent launch. Restored by writing the saved blob back through cfprefsd (`rb`).
     Never write an entry that does not parse as the full shape; always read-modify-write a blob copy that can be restored.
   * Exact shape needed: key `{bundle:{_0:<id>}}`; value `{isAllowed: Bool, location: {bundle:{_0:<id>}}, menuItemLocations:[<loc>...]}` where `<loc>` is the form the system
     would derive from the running process: `{adhocBinary:{_0:{relative:"file://<executable path>"}}}` for ad-hoc signed processes. Not tested: the `<loc>` form
     for Developer-ID signed apps (existing entries use `{bundle:{_0:<bundle id>}}` for them, and helper agents appear as extra `menuItemLocations` elements); the same overwrite rule would apply on a mismatch.
3. **Does removing the entry and relaunching recreate it? YES** (run 2 above, plus a third relaunch: dummy stopped, entry removed, relaunch: recreated within 0.16-0.32 s each time, 4 of 4 relaunch cycles).
   Removal while the app is running does not recreate it (see 1). The removal itself (cfprefsd write) is accepted by the agent without side effects.

## Consequences
* "No entry" is a transient state for a running status-item app: the entry exists 0.2-0.3 s after the app registers its item. An app that looks untracked is (a) not running, (b) was launched
  before the entry existed on this OS install and has been pruned (findings-live-trigger section 5: the Settings extension prunes entries of non-running apps), or (c) the entry was removed while it ran (as in this experiment).
  For (b)/(c) the only recovery that needs no knowledge of the shape is to relaunch the app (the system creates the correct entry) which we must not do on the user's behalf.
* Hiding an untracked running app IS possible by creating the entry, but only with the exact system shape; the guess is cheap for ad-hoc apps (we know the executable) and unverified for signed apps.

## Recipe for the actuator (if gdu.24's follow-up is built)
1. Before declaring `canHide=false` for an item with no entry, re-read `trackedApplications` through cfprefsd (entitled) for >= 1 s after the item was first seen in the snapshot; the system usually creates the entry itself. Only then treat it as untracked.
2. If still absent and the owner is running: read-modify-write the full blob (never a partial/stale blob; keep a copy for rollback): append key `{bundle:{_0:<bundleID>}}` and value
   `{isAllowed:false, location:{bundle:{_0:<bundleID>}}, menuItemLocations:[<loc from the owner's executable: adhocBinary relative file URL if ad-hoc, else {bundle:{_0:<bundleID>}}>]}`, `CFPreferencesSetValue` + `Synchronize`, then verify with the normal hide verification (`hidden=notHosted`) AND a readback >= 2 s later that `isAllowed` is still false and the blob entry count did not shrink.
3. If the readback shows `isAllowed=true` again, the shape was rejected: stop, restore the saved blob, report `cannot be hidden: Control Center would not accept a tracking entry`. If the entry count dropped, restore the saved blob immediately.
4. The `<loc>` form for signed apps is unverified: the follow-up bead must first prove it on a Developer-ID signed dummy (or the user's own signed app, with permission) before the recipe ships; until then keep `canHide=false` for signed untracked apps and say "cannot be hidden: not tracked by Control Center" in the UI.

## Cleanup / end state
Dummy stopped; the full blob restored from the pre-experiment backup through cfprefsd (decoded and byte-equal; the dummy's entry is the pre-existing `isAllowed=1` adhoc entry, as recorded in `orig-entry.plist`); `com.apple.MenuBar.plist` TrailingItemPreferredPositions unchanged (124 keys, no diff);
MenuBarAgent pid 21399 before and after (no restart); Bartender 7 quit during, relaunched after.
