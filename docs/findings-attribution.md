# Findings: the 9th stalled group (gdu.83)

Question: during an iStat stall, reads logged `incomplete: 9 unnamed timeouts, persisted self-positioning groups absent: 8`. Which group is the 9th?

Method (read-only): `mbprobe list --timing --debug --repeat 3` with `SOMMELIER_AX_TRACE=1` (lists every unresolved agent group: frame, child count, cached subtree size) against a copy of `~/Library/Caches/Sommelier/scan-cache.json` (`SOMMELIER_PROBE_CACHE`), and an AX dump of MenuBarAgent (depth 6).

Persisted record: pid 43316 `com.bjango.istatmenus.status`, 8 groups: network, weather, time, disks, battery, cpu, memory, sensors.

Unresolved groups in a stalled read (window 2 of the agent): 8 groups at the frames of those items (e.g. 763,0 49x29; 775,0 37x29; 1150,0 59x29; 845,0 42x29), and a 9th at 975,0 37x29 with ONE child. The dump shows that child is `AXApplication title='iStat Menus Menubar'` (0x0) with `AXMenuBar _NS:430` (Apple, iStat Menus Menubar, File, Edit, Format, View, Window, Help: 8 `AXMenuBarItem` at 0x0 plus their menus, 16 cached elements) and a second `AXMenuBar` (iStat's status bar item). The same shape exists for other agents' apps (Airmail2Hookmark, ControlCenter, VPN Switch) but those answer. The 9th group is therefore iStat's own application group: owned by iStat, stalls only with iStat, answers 0 failures when iStat answers.

Why attribution failed: the entries are `isMainMenuEntry` and are dropped from every read, so no complete read ever recorded the group. Warm scans hid it (cached entries dropped, the group counted as nothing); a cold stall (fresh mbprobe, or the first stall after a group never finished) counted 9 unnamed timeouts against 8 recorded groups. Not Universal Control or DEVONthink Helper: those fail app-side reads, not agent groups.

Fix and measurements: docs/testing.md "Owner application group as the 9th stalled group (gdu.83)", docs/architecture.md "Owner application group (gdu.83)".
