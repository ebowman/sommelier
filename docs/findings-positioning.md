# Findings: repositioning menu bar items (bead sommelier-gdu.5)

Host: macOS 27.0.1, 1920x1200. Date 2026-11-03. Bartender 7 quit for all runs (relaunched at the end). Builds on
`findings-prefstore.md` (gdu.1). Tools: `mbprobe set-position`, `mbprobe watch`, `mbprobe agent-restart`
(`.build/debug/mbprobe`), `make dummy` (MBDummy.app, bundle id `ie.boboco.mbdummy`, items Dummy-A/B titled DA/DB).
Evidence: `evidence/gdu5-baseline.json` (full `mbprobe list --json` before everything, Bartender running),
`evidence/gdu5-agent-plist-before.plist` (byte copy of the agent plist before the first edit; the agent rewrites values on
restart so byte identity is not expected, only order). A full scan takes 1-12 s, so "observe" = scans spaced through the window.

## Experiments

| # | Command(s) | Result |
|---|---|---|
| A | `mbprobe set-position ie.boboco.mbdummy Dummy-A 5000` and `Dummy-B 10` (also with `--host`); watch/scan for ~40 s. Initial order DB, DA. | No change. `defaults read ie.boboco.mbdummy` shows the keys, bar unchanged. |
| A' | Reverse values (A=10, B=5000), both host variants | Direction ambiguity removed: still no change. |
| B(i) | `make dummy-stop && make dummy` with legacy keys present (both directions) | Not honored: DB, DA both times. |
| B(ii) | `killall MenuBarAgent` after the legacy write (both directions) | Not honored. **Legacy `NSStatusItem Preferred Position` writes have no effect at all on this OS.** (The `--retoggle` isVisible idea was not built: the agent store makes it moot.) |
| C1 | `mbprobe set-position MBDummy Dummy-A 1000 --store agent; ... Dummy-B 900 --store agent; mbprobe agent-restart` (swap) | DB,DA -> DA,DB (x 1010 / 1078). Works. |
| C1' | Same with key `status:ie.boboco.mbdummy::Dummy-A/B` (bundle id) | IGNORED: key was written (and persisted) but never consulted, in 3 variants incl. relaunch. The agent keyed the ad-hoc-signed dummy as `status:MBDummy::<autosave>` (process / code-signature identifier, not CFBundleIdentifier). Hypothesis (untested): the ad-hoc signature identifier is `MBDummy` because the bare Mach-O has no bound Info.plist. Third-party signed apps use their bundle id (KeepingYouAwake works with it). |
| C2 | `... Dummy-A 7000 --store agent; agent-restart` | DA is the leftmost visible item (x=1010, left of Wi-Fi/SystemUIServer). Large = far left, confirmed. |
| C3 | `... Dummy-A 5 --store agent; agent-restart` | DA moves to x=1801, immediately LEFT of Control Center (x=1841) and the clock (1878); it does not go between Control Center and the clock (`module:BentoBox-0`=18, `module:Clock`=0). So the rightmost slot available to third parties is just left of Control Center. |
| C4 fresh key | `make dummy ARGS="--count 4"` -> Dummy-D has no key; a new item is placed leftmost by default (x=948). `set-position MBDummy Dummy-D 7000` (no visible change, already leftmost), then `... 100 --store agent` + restart | DD goes to x=1717 (far right). **The agent accepts a key that did not exist before** and positions by it. The agent itself did not create a key for the new item before the restart. |
| C5 untouched items | Non-dummy on-bar order compared (bundle/identifier lists) with DA at 761 vs 5 vs 7000, each across a restart | Identical (only noise: WiFi Signal text 64%/65%). |
| C6 restart cost | `mbprobe agent-restart` x11 | Respawn (launchd) is automatic. Measured elapsed (killall to hosted AX count >= 90% of pre-kill count): 2.4-2.7 s when scans were stable (6 runs), 4.5-5.8 s (5 runs); two runs hit the 10 s timeout on a stale/noisy count (one reached 149 only at the timeout; one stopped at 75 of 135 and was complete ~5 s later). Each count poll costs 1-2 s itself, so true recovery is likely <=2 s (gdu.1 saw ~2 s). The hosted count is noisy (133-151 for the same bar: AX read timeouts), hence the 90% threshold. |
| D | `set-position info.marcel-dierkes.KeepingYouAwake Item-0 600 --store agent` + restart (original 598; TextInputMenuAgent=596 was just left of it) | KeepingYouAwake moved one slot left (x 1279 -> 1253, past Emoji & Symbols). Restore `598` + restart: order identical to before. Other items untouched. |
| End | Original plist bytes restored (atomic mv), `agent-restart`, `open -a "Bartender 7"` | On-bar order (23 items) identical to `gdu5-baseline.json`. MBDummy stopped, Bartender running. |

Notes: stale keys exist from earlier runs (`status:MBDummy::Dummy-C`=821). The agent rewrites every value on its own
(e.g. A 761 -> 723) but preserves relative order. One AX scan during D omitted Control Center (AX flake, not a move).
Hidden (non-allowed) items stayed parked across every restart, no menus were left open, and the only visible side effect is a
brief bar blank/flash of ~1-2 s while the agent respawns.

## Conclusion
Legacy per-app `NSStatusItem Preferred Position <autosave>` writes (any host variant) do NOT reposition, live or after app
relaunch or `killall MenuBarAgent`. The reliable mechanism is: write `TrailingItemPreferredPositions[status:<id>::<autosave>]`
in `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist` (atomic write, keep file mode,
never touch `module:`; larger number = further left, only relative order matters, fresh keys are accepted), then
`killall MenuBarAgent`. Restart cost ~2-3 s typical (<=6 s measured by polling), visible as a 1-2 s bar flash, no logout,
hidden items stay hidden, untouched items keep their order. Limits: third-party items cannot be placed right of Control Center;
the key id is the process/signature identifier, which for a properly signed app equals its bundle id but not for ad-hoc
unbundled test binaries (verify key by checking that the agent honors it).

**Recommendation for T07:** use the agent-store write + `killall MenuBarAgent` (`MenuBarOrderStore` + `MenuBarAgentControl`),
batching all moves into one restart; verify with the scanner; do not use legacy preference writes.
