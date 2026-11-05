# Findings: the 9th stalled group (gdu.83)

Question: during an iStat stall, reads logged `incomplete: 9 unnamed timeouts, persisted self-positioning groups absent: 8`. Which group is the 9th?

Method (read-only): `mbprobe list --timing --debug --repeat 3` with `SOMMELIER_AX_TRACE=1` (lists every unresolved agent group: frame, child count, cached subtree size) against a copy of `~/Library/Caches/Sommelier/scan-cache.json` (`SOMMELIER_PROBE_CACHE`), and an AX dump of MenuBarAgent (depth 6).

Persisted record: pid 43316 `com.bjango.istatmenus.status`, 8 groups: network, weather, time, disks, battery, cpu, memory, sensors.

Unresolved groups in a stalled read (window 2 of the agent): 8 groups at the frames of those items (e.g. 763,0 49x29; 775,0 37x29; 1150,0 59x29; 845,0 42x29), and a 9th at 975,0 37x29 with ONE child. The dump shows that child is `AXApplication title='iStat Menus Menubar'` (0x0) with `AXMenuBar _NS:430` (Apple, iStat Menus Menubar, File, Edit, Format, View, Window, Help: 8 `AXMenuBarItem` at 0x0 plus their menus, 16 cached elements) and a second `AXMenuBar` (iStat's status bar item). The same shape exists for other agents' apps (Airmail2Hookmark, ControlCenter, VPN Switch) but those answer. The 9th group is therefore iStat's own application group: owned by iStat, stalls only with iStat, answers 0 failures when iStat answers.

Why attribution failed: the entries are `isMainMenuEntry` and are dropped from every read, so no complete read ever recorded the group. Warm scans hid it (cached entries dropped, the group counted as nothing); a cold stall (fresh mbprobe, or the first stall after a group never finished) counted 9 unnamed timeouts against 8 recorded groups. Not Universal Control or DEVONthink Helper: those fail app-side reads, not agent groups.

Fix and measurements: docs/testing.md "Owner application group as the 9th stalled group (gdu.83)", docs/architecture.md "Owner application group (gdu.83)".

## Flapping items between consecutive reads (gdu.86)

Measured read-only (cache copy, `mbprobe list --timing --debug --repeat 3`, 6 runs before the change):

| run | stalled reads | hosted time | failed | level / reason | vanished between reads |
|---|---|---|---|---|---|
| 1 | scans 2, 3 | 2725, 619 ms | 9 | `exceptSelfPositioning` | nothing |
| 2, 3, 5 | none | 40-1700 ms | 0 | `complete` | nothing |
| 4 | 1, 2, 3 | 2872, 2724, 2740 ms | 9 | `incomplete`: cold record (absent 7, previous-tree absent 12), then `non-self-positioning element missing (frame:799,4,22)`, then `(frame:795,3,30)` | pile items (frames 799/w22, 795/w30 = KeepingYouAwake) |
| 6 | 1, 2 | 2873, 623 ms | 9 | scan 2 `incomplete`: `non-self-positioning element missing (id:com.apple.menuextra.wifi)`; scan 3 complete | Wi-Fi (and Focus: "2 previously visible item(s) absent; re-reading") |

Why: Wi-Fi and Focus are Control Center modules the agent re-publishes (absent for a read); pile items sit behind the chevron where macOS re-lays them out, so their frame-keyed identity changes or the element is absent in a stall. Each put a non-self-positioning element in `miss`, so `attributable` was false, the read `.incomplete`, and gdu.81 cleared the caps (the next stall paid ~2.7 s). Rule (gdu.86, docs/architecture.md): volatile modules and elements whose last frame lies in the pile (`SystemOverflowRule`) do not count in `miss`. After: docs/testing.md.
