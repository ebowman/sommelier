# Findings: live hide/show trigger for MenuBarAgent (bead sommelier-gdu.36)

Host: macOS 27.0.1, 1920x1200, 2026-11-04. Subjects: MBDummy items only (`ie.boboco.mbdummy`, Dummy-A/Dummy-B). Bartender 7 was quit for the run
and relaunched afterwards. Evidence (not in repo): `scratchpad/gdu36/` = `signals-run1-hup-usr1-usr2.log`, `signals.log`, `darwin.log`,
`dist.log`, `recheck.log`, `log-toggle.txt` (+ `log-excerpts.txt`), `log-ent-hide.txt`, `log-ent-show.txt`, `bar-live-*.png`, `ccset2.swift`.

## 1. Conclusion (read this first)
**A live path exists, and it is not a signal, a notification or XPC: it is the cfprefsd change notification for the preferences domain
`group.com.apple.controlcenter`.** MenuBarAgent keeps a `CFPrefsPlistSource` for that domain; when any client writes the key
`trackedApplications` THROUGH cfprefsd, cfprefsd sends MenuBarAgent a "remote change notification", MenuBarAgent logs
`[com.apple.ControlCenter:SystemItemMenuBarPreferences] Preferences: changed`, re-evaluates `isAllowed` and, within ~20 ms, invalidates /
unregisters the status-item scenes of the newly disallowed app (hide) or re-registers them (show). No respawn: MenuBarAgent pid unchanged, the
rest of the bar does not flash and keeps its slots (screenshots `bar-live-before/hidden/shown.png`).
Everything we did before wrote the plist FILE directly (`mbprobe cc-allowed set`, atomic rename), which bypasses cfprefsd, so MenuBarAgent never
heard about it and only picked it up at launch. That is why only a respawn applied it.

## 2. Trigger table (flag flipped to 0 first; "on" = still shown, judged by agent log "Unregistering scene" + screenshot, see caveat in §4)
| Trigger | Result | Latency | pid changed? |
|---|---|---|---|
| Baseline `cc-allowed set 0` + `killall MenuBarAgent` (`agent-restart`) | hides; bar blanks | `agent-restart` reported 6.5 s (hide) / 1.2 s (show); wall to first `list` showing it ~15 s / ~5 s (each `mbprobe list` scan itself takes ~3 s) | yes |
| SIGHUP | agent TERMINATED (default action), respawn applied hide | applied in <=1 s | yes |
| SIGUSR1 | agent terminated, respawn applied hide; respawn took 6-10 s (launchd throttling after repeated kills) | 6-10 s | yes |
| SIGUSR2 | same as SIGUSR1 | 6-10 s | yes |
| SIGINFO | no effect (15 s, plus re-test 5 s with scene log) | n/a | no |
| SIGCONT | no effect | n/a | no |
| SIGWINCH | no effect | n/a | no |
| SIGALRM | agent terminated, respawn applied hide | <=1 s | yes |
| `notifyutil -p` x55 candidate names (6 batches of 10, 3 s apart; list in `notify-candidates.txt`/`notify-post-list.txt`) | no effect (twice: AX-based and scene-log-based) | n/a | no |
| Distributed notification (`DistributedNotificationCenter`, 10 names) | no effect (twice) | n/a | no |
| Apple's own toggle (System Settings > Menu Bar > "MBDummy" switch, driven with System Events) | LIVE hide and show | `Preferences: changed` -> scenes invalidated +23 ms (click-to-change latency not reproducible from evidence) | no |
| Direct file write (`mbprobe cc-allowed set`, or CFPreferences with the absolute-path domain `.../group.com.apple.controlcenter`) | file changes, MenuBarAgent never notified, no effect until respawn | n/a | no |
| **CFPreferences write to domain `group.com.apple.controlcenter` from a process carrying entitlement `com.apple.security.application-groups = [group.com.apple.controlcenter]`** (`ccset2`) | **LIVE hide and show** | write -> notification 13 ms -> scenes (un)registered +24 ms; gone from bar in <0.9 s | **no** |
| Same CFPreferences write WITHOUT the entitlement | resolves to `~/Library/Preferences/group.com.apple.controlcenter.plist` (does not exist): read returns nil, nothing reaches the agent | n/a | no |
| XPC `com.apple.MenuBarAgent.VisibilityRestrictionServer` | NOT attempted: the log shows no XPC for the toggle, and the strings (`didActivateVisibilityRestriction`, `requestMenuBarVisibility`, `MenuBarVisibilityRequestSource`) relate to whole-bar auto-hide/visibility assertions, not per-app isAllowed | n/a | n/a |

## 3. Apple's own path (log excerpt, `log-toggle.txt`)
```
07:08:28.249 MenuBarAgent  Received remote change notification from process 85952 (ControlCenterSettings.appex) for { domain: <private> ...}
07:08:28.250 MenuBarAgent  [com.apple.ControlCenter:SystemItemMenuBarPreferences] Preferences: changed
07:08:28.273 MenuBarAgent  [FrontBoard:Scene] Invalidating scene: com.apple.appkit.status-items:...-Variant[2]
07:08:28.273 MenuBarAgent  [FrontBoard:ProcessWorkspace] [app<ie.boboco.mbdummy>:77233] Unregistering scene: ...
07:08:47.067 MenuBarAgent  (toggle back ON) Registered new scene: com.apple.appkit.status-items:...-Variant[3]
```
Settings' extension holds the app-group entitlement, so its CFPreferences calls land in the Group Container file and cfprefsd fans the change out
to MenuBarAgent and ControlCenter. Note the extension also reacts to changes and may rewrite the blob (pruning entries of apps that are not
running); see §5.

## 4. Verification caveat (important for the engine)
After a live hide, the owning app's own AX frames stay ON-BAR (x=1036/1066, `"isOnMenuBar": true`; at most a 1 px shift, e.g. Dummy-A
[[1066,3],[32,24]] -> [[1067,4],[22,22]]). The `stale` flag in `list --json` is UNRELIABLE (I saw it flip once; the reviewer's clean 10 s poll
saw it stay false). Parked x in -1..3 only appears after a respawn. Detect a live hide via (a) the MenuBarAgent scene log
(`Unregistering scene` / `Registered new scene` for the bundle), (b) MenuBarAgent's hosted AX window children (TESTED in gdu.38: 1.5 s after `ccset ... 0` the agent's hosted tree contains NO Dummy-A/Dummy-B elements at all - not parked, simply absent - while the app's own `AXExtrasMenuBar` still reports both at their on-bar frames (x=784, y=2, 32x24); after `ccset ... 1` both are hosted again within 2 s; this is the signal `MenuBarScanner` uses, see `MenuBarItem.hidden == .notHosted`; it is reported by the first COMPLETE full scan after the write, 1.0-4.1 s measured, and an incomplete first scan still reports on-bar, so poll until a complete read, see docs/testing.md), or (c) a respawn. The earlier "no effect" rows were re-run with the scene log as the oracle
(`recheck.log`: zero "Unregistering scene" for every trigger except those that killed the agent).

Identifier-less items (Tot, Yoink, Moom) cannot be judged by name; their live hide is detected by write-time hosted-count evidence and the
`assumedNotHosted` state (of7, docs/architecture.md Hide / show row; live table in docs/testing.md).

## 5. Caveats / risks
* The writer must go through cfprefsd under the group domain. On this dev machine an AD-HOC signed binary with `com.apple.security.application-groups =
  group.com.apple.controlcenter` can read and write it (`CFPreferencesSetValue(key, data, "group.com.apple.controlcenter", kCFPreferencesCurrentUser,
  kCFPreferencesAnyHost)` + `CFPreferencesSynchronize`; NOT `CFPreferencesSetAppValue`/`AppSynchronize`, which returned false). Whether a
  Developer-ID/notarized Sommelier is allowed that Apple-reserved group is UNVERIFIED (AMFI/containermanagerd may refuse). Currently
  `Resources/Sommelier.entitlements` is an empty dict.
* Concurrent writers: the first write (isAllowed=0) triggered a second change notification from ControlCenterSettings.appex pid 85952 while
  System Settings was open, and the blob afterwards lacked 8 entries (all `isAllowed=true`, non-running apps: Tailscale, FastScripts, iStat helper,
  ChatGPT helper, three MBDummy variants). I restored the backup blob through cfprefsd after quitting Settings; blob is byte-identical to the backup.
  Read-modify-write with the full blob only; never write a blob built from a stale read.
* Persistence: the live-written value survives a MenuBarAgent respawn (reviewer: hide 07:21:04.555, killall 07:21:06.649, new pid brought the dummies back parked at x=-1). But the on-disk plist LAGS the cfprefsd write: 2 s after the write the file still read isAllowed=1 and only later read 0. A verifier must not read the file right after writing; read back through CFPreferences or wait for agent-side evidence.
* Rapid repeated kills make launchd delay the respawn (6-10 s seen); another cost of the respawn path.

## 6. Recommendation for LiveActuator
Wire the cfprefsd write in as the PRIMARY hide/show mechanism (instant, no flash, no pid change, other items keep slots; batch changes into one
blob write), keep `isAllowed` file write + `agent-restart` as the FALLBACK when (a) the entitlement is unavailable (nil read / sync false),
or (b) post-write verification (scene log / agent hosted list) does not confirm within ~1 s. Follow-up beads: (1) engine: cfprefsd writer + entitlement
in `Sommelier.entitlements` and signing, with respawn fallback; (2) scanner must detect live-hidden items via the agent's hosted list, not the app's frames or the stale flag; (3) investigate
Developer-ID signing viability for the app-group entitlement; (4) check how live-shown items re-order (they came back in their old slot here).

## 7. Reproduce
Tools in the repo: `scripts/ccset.swift` + `scripts/ccset.entitlements` (the entitled writer; MBDummy only).
```
make build && make dummy; osascript -e 'tell application "Bartender 7" to quit'
P=$(swift build --show-bin-path)/mbprobe
# baseline respawn path
$P cc-allowed set ie.boboco.mbdummy 0; $P agent-restart
# signals (flag written to file only)
kill -<SIG> $(pgrep -x MenuBarAgent)         # HUP USR1 USR2 INFO CONT WINCH ALRM
# darwin names
strings -a /System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent | grep -E 'com\.apple\.(controlcenter|menubar|MenuBar|MenuBarAgent|systemuiserver|sysuis)'
notifyutil -p <name>
# trace (use /usr/bin/log: zsh has a builtin 'log')
/usr/bin/log stream --style compact --info --debug --predicate 'process == "MenuBarAgent" OR process == "ControlCenter" OR process == "System Settings" OR subsystem CONTAINS "menubar" OR subsystem CONTAINS "controlcenter"' > log.txt &
# poll loop: AX frames (note: unreliable for live hide, see section 4) plus scene log
for i in $(seq 1 20); do date +%T.%N; pgrep -x MenuBarAgent; $P list | grep MBDummy; grep -c 'Unregistering scene.*mbdummy' log.txt; sleep 0.5; done
# Apple's toggle
open "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"   # click the MBDummy switch via System Events (osascript -l JavaScript)
# the live trigger
swiftc -O -o ccset scripts/ccset.swift && codesign -s - -f --entitlements scripts/ccset.entitlements ccset
./ccset ie.boboco.mbdummy 0     # hides live
./ccset ie.boboco.mbdummy 1     # shows live
```
Not in repo: `dpost` was a tiny DistributedNotificationCenter poster that posted the 10 names; `recheck.sh` re-ran the no-effect triggers with the scene log as oracle.

## 8. Signing gate (gdu.40, 2026-11-04)
Question: does the cfprefsd live hide/show (needs `com.apple.security.application-groups` = `group.com.apple.controlcenter`) survive Developer ID signing, hardened runtime and notarization? Subject: `scripts/ccset.swift` + `scripts/ccset.entitlements` (the same entitlement Sommelier will carry), MBDummy only, Bartender quit, macOS 27.0.1, Developer ID Application: Eric Bowman (Y5SB82BPYL).

| Variant | codesign OK | notarization status | live hide applied (pid unchanged?) | latency to first complete scan | denials/dialogs |
|---|---|---|---|---|---|
| (a) ad-hoc + entitlement (control) | yes | n/a | yes: `Preferences: changed` 07:54:38.840, `Unregistering scene` +32 ms; show re-registered scenes (pid 13802 before/after) | 7.2 s (first scan after write had 8 failed reads, second had 0) | none, no dialog |
| (b) Developer ID + `--options runtime --timestamp` + entitlement | yes (`valid on disk`, satisfies DR; flags=0x10000(runtime); TeamIdentifier=Y5SB82BPYL) | n/a | yes: change 07:55:07.670, `Unregistering scene` +29 ms; show re-registered (pid unchanged) | 3.9 s (first scan complete) | none, no dialog |
| (c) same build and signing flags as (b), notarized | yes | Accepted (statusCode 0, `issues: null`) | yes: change 07:55:54.200, `Unregistering scene` +29 ms; show re-registered (pid unchanged) | 4.5 s (first scan complete) | none, no dialog; `spctl -a -t execute`: "rejected (the code is valid but does not seem to be an app)" with `origin=Developer ID Application`, expected for a bare CLI binary |

Notes on method. Latency is write to the end of the first `mbprobe list --json --debug` whose agent-tree read reported 0 failed reads (a scan itself takes 2-5 s, so this is an upper bound; the agent reacts within ~30 ms per the log). This run did not pre-scan and its scan helper did not record the `hidden` field, so the scene log was used as the oracle. Since gdu.38 the scanner reports a live-hidden item as `hidden=notHosted` / `isOnMenuBar=false` on the first complete read, provided the item was seen hosted in an earlier complete read (persisted `seenHostedKeys`; keys include the owner pid, so a freshly launched app needs one complete scan first). The reviewer's re-run of (b) with two seeding scans confirmed this: 12 of 12 hidden-state scans across 3 cycles reported `notHosted`, 0 real items flagged. gdu.39's verifier can therefore use the scanner, seeded, instead of the log; the on-bar reading in (c) at 4.5 s is unexplained but was not reproduced. `log stream` with the broad predicate drops messages under load ("Messages dropped"), so scene lines for (b) and (c) were taken with `log show` over the same window.
Relevant log lines (all three variants look alike):
```
MenuBarAgent [com.apple.ControlCenter:SystemItemMenuBarPreferences] Preferences: changed
MenuBarAgent [com.apple.FrontBoard:ProcessWorkspace] [app<...ie.boboco.mbdummy...>] Unregistering scene: <... com.apple.appkit.status-items:...-Variant[1]>   (x2)
MenuBarAgent ... Registered new scene: <... com.apple.appkit.status-items:...-Variant[4]>   (x2, after the show write)
cfprefsd rejecting read of CFPDContainerSource (Domain: group.com.apple.controlcenter ... ByHost: No) from process ccset-<variant> because (null)
cfprefsd rejecting write of key(s) <private> in CFPDContainerSource (Domain: group.com.apple.controlcenter ...) from process ccset-<variant> because (null)
cfprefsd Process ccset-<variant> wrote the key(s) <private> in CFPDContainerSource (...group.com.apple.controlcenter..., Dirty: Yes)
```
The two "rejecting ... because (null)" lines appear identically for the ad-hoc control and for Developer ID (b); each is immediately followed by `read data`/`wrote the key(s)`, so they are a first-attempt probe, not a denial. A dedicated `log stream --predicate 'process == "cfprefsd"'` capture of (b) shows no line mentioning the entitlement or application-groups; the entitlement is checked silently. No amfid/syspolicyd/tccd denial and no "wants to access data from other apps" consent dialog (screenshots of each hidden state inspected).
Notarization log: `status Accepted`, `issues: null`; nothing flagged, so nothing excerpted (the log names only the binary cdhash).

Verdict. On this machine (macOS 27.0.1, existing user session), a Developer ID signed, hardened-runtime, notarized binary carrying `group.com.apple.controlcenter` gets the same live hide/show as the ad-hoc build: Apple's notary accepted the entitlement, the hardened runtime did not block the cfprefsd container access, MenuBarAgent reacted within ~30 ms and its pid never changed. So gdu.39 can keep the live path as primary for released builds, with the respawn fallback still required. NOT proven: (1) a bare CLI tool, not an app bundle: a real .app with an embedded provisioning profile, a stapled ticket or Gatekeeper first-launch assessment was not exercised (an app bundle quarantined via download could behave differently); (2) a different Mac or fresh user with clean TCC/consent state, where macOS 15+ app-group validation could prompt; (3) macOS 26 (only 27.0.1 was available); (4) future OS policy tightening of Apple-reserved group identifiers; (5) the cfprefsd-ignores-entitlement case is covered only by the fallback (nil read / sync false / no scene change within ~1 s).

## Post-write verification cost under an iStat stale streak (gdu.77)
Question: why does post-write verification of a reveal/re-hide take ~3 s whenever iStat is stale (gdu.71 live: 0.75-2.96 s)?
Evidence (2026-11-05, Sommelier from the gdu.77 build, Bartender quit, MBDummy x2; app logs `r77/app.log`, `r77/app2.log` in the scratchpad, `mbprobe list --timing --debug`):
* The verification is `LiveActuator` live path: setAllowedLive + `isAllowed` readback (0.2-0.9 s; `write applied` log), then a loop of `liveVerifyInterval` (0.5 s sleep) + ONE scan per poll. During a streak (previous full read `.completeExceptSelfPositioning`) polls 1 and 2 are fast hosted reads (`fastConfirmEvery = 3`), poll 3 a full scan. Typical healthy numbers (iStat answering): `verified by fast hosted read #1` 713-1029 ms from batch start, `verified by complete read #1` 718-1526 ms. SettleDetector is NOT in this path (it belongs to the drag path), so `stableFor`/`settleMaxWait` do not contribute.
* The long cases are a single SCAN that takes 2.3-3.3 s, not the polling schedule: 04:03:48 hide, `1 scans ... 4065 ms ... read level completeExceptSelfPositioning` = 0.3 s write + 0.5 s sleep + a ~3.3 s full scan; 03:57:24 first hide: 3500 ms = fast #1 (1.2 s after the write, not confirming), fast #2 (0.9 s), full #3 (1.2 s).
* Where the scan time goes (`mbprobe list --timing --debug`, one-shot process, same machine, alternating): `agent tree read (32 elements, 8 failed reads, 0 timed out) at 2497 / 2453 ms` and `scan time: 2598 / 2539 ms` when iStat does not answer, versus `agent tree read (40 elements, 0 failed reads) at 434 / 954 ms` and `scan time 888 / 1013 ms` when it does. So ~1.6-2 s of the full scan is the MenuBarAgent hosted-tree read waiting on iStat's 8 agent groups: first pass with `agentTimeout` 0.5 s, then the retry round (`agentRetryTimeout` 1.0 s, `agentRetryWindow` 1.2 s), plus the app pass. The gdu.51 cap (`agentSlowGroupTimeout` 0.3 s, no retry round) only applies to groups the PREVIOUS full read left unresolved AND attributed to self-positioning owners (`AXElementCache.spSlow`); the first full read after iStat turns stale (typically the verification scan, or the first scan of a pass after idle) therefore pays the whole 0.5 + 1.2 s budget, and the cap is dropped again by any full read that resolves the groups (`setSlow`), so an iStat that alternates answered/stale (as here) re-pays it.
Conclusion: the ~3 s is the cost of the first full scan after iStat goes stale (AX timeouts of its 8 groups: 0.5 s + 1.2 s retry round + app pass), unrelated to the settle detector, `fastConfirmEvery` or the poll interval.
Bounded improvement: NOT implemented. The candidate is to keep a group in `spSlow` (capped, no retry) for a hysteresis period (say 60 s) after the last read that left it unresolved, instead of dropping it on the first read that resolves it, so an alternating iStat does not re-pay the retry round (expected: stale full scans ~0.9 s instead of ~2.5 s). It changes gdu.51's scanner/AX-cache semantics (what is capped when), is cross-cutting rather than a confirm-path tweak, and could not be validated safely live in this task (see the live incident in docs/testing.md), so it is recorded here as a proposal for its own bead. The gdu.55/26/27 rules are untouched.

## 9. Incident 2026-11-05 (gdu.79): stale app-side frames classed as on-bar, a user-hidden item was shown

After live hides, `mbprobe list` reported 1Password, BoltAI, Tailscale, TextSniper, RescueTime, DEVONsphere, Grammarly, Script Menu and Jump ON BAR at x 781-803: source `appExtras` only, no hosted MenuBarAgent element, Control Center `isAllowed=0`. `mbprobe layout init-from-current` therefore wrote them to the scratch layout's `visible` section, and when the engine later observed BoltAI parked it SHOWED it (wrote `isAllowed=true`). The same misclassification made the real-layout plan skip HoudahSpot as "in the system overflow area". Cause: section 4 (the owner's AX frames and `stale` do not change after a live hide) was handled only for items the scanner had SEEN hosted (`notHosted`) or that WE hid (`assumedNotHosted`); an item hidden by someone else (Bartender) had neither. Fix: docs/architecture.md "Placement authority": no hosted element means the Control Center flag decides (false => hidden; otherwise unknown), plus an engine guard against showing a flag-false key the user did not place.
Live check with MBDummy only: see docs/testing.md "gdu.79".
