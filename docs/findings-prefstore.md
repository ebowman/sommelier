# Findings: MenuBarAgent order store (bead sommelier-gdu.1)

Host: macOS 27.0.1, 1920x1200 display. Date 2026-11-03. Evidence in `docs/evidence/`. Tools: `scripts/axdump.swift`
(AX enumeration, ~20 s per run because of per-app AX timeouts; occasionally drops an app that timed out),
`scripts/cmddrag.swift` (synthesized Cmd+drag), `scripts/plistcmp.py` (value diff of two plists).
Method note: human-only steps (2, 5b) were done with the synthesized drag instead.

## 1. File location and key format
`~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist` (path contains a space; quote it).
Single top-level dict `TrailingItemPreferredPositions` with 87 keys: `status:<bundleID>::<autosaveName>` (e.g.
`status:info.marcel-dierkes.KeepingYouAwake::Item-0`) and `module:<Name>` (e.g. `module:Clock`=0). Values are a mix of
`integer` (Apple-seeded) and `real` (after MenuBarAgent rewrites). Baseline: `evidence/menubar-plist-before.txt`, `baseline.plist`.
Note: keys can be stale/duplicated (`status:FloTile::Item-0` and `status:ie.boboco.FloTile::Item-0`; `status:Item-0`).

## 2. Units / origin / writer
Value is points from the right screen edge; larger = further left. Empirically value ~= (1920 - item.left_x) - ~70
(Airmail left 1806 -> 44; Bartender GoldenGateBar 1780 -> 69; KeepingYouAwake 1244 -> 603; VPN Switch 1639 -> 215; FloTile 1692 -> 157;
spread +-4, items with variable width such as WiFi Signal drift more). Clock=0, BentoBox-0 (Control Center)=18.
Writer is MenuBarAgent, not the app: a synthesized Cmd+drag of KeepingYouAwake one slot left (it moved: AX x 1244 -> 1218,
neighbor TextInputMenuAgent 1218 -> 1246) rewrote the plist (mtime changed, `evidence/diff-drag1.txt`: KeepingYouAwake 551 -> 629,
TextInput 579 -> 603) while the app's own defaults `NSStatusItem Preferred Position Item-0` stayed 338.
The write renormalizes EVERY value (all 87 keys moved by +13..+68, most +52/+53, parked items included) and rewrites them as reals.
Dragging back restored the visual order but not the numbers (`evidence/cmp-baseline-vs-back1.txt`). So only relative order is
meaningful; absolute numbers are re-derived by the agent. The synthesized drag (CGEvent, Command flag, 10 steps x 15 ms,
.cghidEventTap) WORKS, which is itself valuable: reorder can be driven without a human. No "HUMAN DRAG NEEDED" items.

## 3. Hidden-state representation
Not in `com.apple.MenuBar.plist` (hidden Yoink=854, Tot=814 look like ordinary values) and not in the app's
`NSStatusItem` defaults (Yoink 5900/Tot 6389 are legacy Bartender-style park values with no visible effect found).
Hidden state is the macOS "Allow in the Menu Bar" flag: `trackedApplications` in
`~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`
(data blob, itself a binary plist: array of `{location, menuItemLocations[bundle ids], isAllowed}`). Decoded:
`evidence/controlcenter-trackedApplications-before.txt`, `controlcenter-allowed-before.txt`. All 35 apps with `isAllowed=False`
(Yoink, Tot, Dropbox, 1Password, Magnet, Moom, Alfred, ...) are exactly those AX shows parked at x=-1..3, y=1188/1204 (below the bar);
allowed ones are on the bar. Parked items keep their order values. Bartender 7 runs in `GoldenGateHidingMode = compatibility`
and drives this flag (it holds a bookmark to this file; `GoldenGateCompatibilityOriginalAllowedStates` stores the pre-Bartender values).
Quitting Bartender did NOT un-hide anything or change the Control Center plist (byte-identical). NOT tested: flipping `isAllowed`
live (needs a blob write; Bartender UI could not be driven headlessly; its AppleScript `list menu bar item details` hung).

## 4. Live reload: NO
With Bartender quit, swapping VPN Switch (215) and MCP Maestro (187) in the file (atomic write, then also via `defaults write <fullpath>`)
produced no change over 4 AX dumps (~80 s). File is read at MenuBarAgent launch only. Moreover the agent holds state in memory:
after an in-process drag the agent overwrote my external edit (KeepingYouAwake set to 629 in file; drag of an unrelated item
rewrote it as 747 and the bar kept the in-memory position). External edits are lost on the next agent write.

## 5. Trigger table (`evidence/ax-step4-swapped.txt`, `ax-d-killagent.txt`)
| Trigger | Result |
|---|---|
| (a) `defaults write "<full plist path>" TrailingItemPreferredPositions -dict-add ...` | no effect (30+ s) |
| (b) Cmd+drag of an unrelated item | no re-read; agent overwrites file from memory (external edit lost) |
| (c) quit/relaunch owning app (VPN Switch) | no effect (item just re-registers, same slot) |
| (d) `killall MenuBarAgent` | WORKS. Respawned by launchd in <1 s (new pid), no manual start needed; bar back in ~2 s; new order applied (MCP Maestro 1670 left of VPN Switch 1695); file mtime unchanged (agent does not rewrite on launch); hidden items stayed hidden. |
(`killall cfprefsd` was not used.)

## 6. Large values
Entries > 5000 (RHSItem 5928, fastscripts 5948, Spotlight 6118/6128, tailscale.macos 6028, VLC 6348, MacWhisper 6358, Parallels 6398)
all belong to apps not running at the time (or Bartender's own separator while Bartender was quit): absent from the bar and AX, no
parked frame. Setting running KeepingYouAwake to 7000 + `killall MenuBarAgent`: it appeared as the leftmost visible third-party
item (x=1040, y=3, visible, not parked; `evidence/ax-step6-7000.txt`). So large = "as far left as possible", not hidden;
Bartender's 5xxx-6xxx values are just sentinel far-left slots, and the plist value does not hide anything.

## 7. Recommendation for T07
Preference-driven order is VIABLE WITH TRIGGER: edit `com.apple.MenuBar.plist` (only relative order matters; use sparse distinct
values, never touch `module:`), then `killall MenuBarAgent` (instant respawn, ~2 s flicker, no logout) and optionally verify with AX.
Do not rely on live file watching and do not write while an in-app drag could happen (agent clobbers). Alternative with no
flicker: synthesized Cmd+drag via `scripts/cmddrag.swift` (worked, lets agent persist). Hide/show = `isAllowed` in the
Control Center plist blob (not yet tested live).

## 8. End state
Plist restored to baseline (values identical, `evidence/plist-final4.txt` vs `menubar-plist-before.txt`; bytes differ because the
agent rewrote it as reals/binary). Control Center plist byte-identical. Bartender 7 relaunched. Visible AX order equals baseline
(`ax-final4.txt` vs `ax-before.txt`; only noise: DEVONthink missing in baseline due to AX timeout, Keyboard Maestro Engine now
parked where baseline showed a phantom x=1205 entry).
