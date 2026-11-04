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
(`Unregistering scene` / `Registered new scene` for the bundle), (b) MenuBarAgent's hosted AX window children (whether the item disappears
from the agent's own list was NOT tested), or (c) a respawn. The earlier "no effect" rows were re-run with the scene log as the oracle
(`recheck.log`: zero "Unregistering scene" for every trigger except those that killed the agent).

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
