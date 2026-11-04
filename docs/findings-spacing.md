# Findings: status item spacing (sommelier-gdu.20)

Machine: macOS 27.0.1, 2026-11-04. Bartender 7 stayed running (no actuation). Keys were absent before and after.

## Mechanism
`NSStatusItemSpacing` and `NSStatusItemSelectionPadding` are written to the global domain, current user, current host
(`CFPreferencesSetValue(..., kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)` + synchronize),
which is `~/Library/Preferences/ByHost/.GlobalPreferences.<hostUUID>.plist`. Cross-check:
`defaults -currentHost read -globalDomain NSStatusItemSpacing` prints the value (and "does not exist" when unset).
`mbprobe spacing get|set <spacing|-> <padding|->|reset` does this and prints the defaults read result.

## Measurements (`mbprobe list --json`, frame widths; mbdummy items have 2-letter titles)
Default width of a dummy item is 32/32/33 (A/B/C). The measured width follows `24 + spacing` for the dummy items.

| Setting | Already-running apps (5 s after set) | Dummies relaunched (`make dummy-stop && make dummy`) |
|---|---|---|
| baseline (keys absent) | dummies 32/32/33 | 32/32/33 |
| spacing 2 | unchanged: dummies 32/32/33; WiFi 61, VPN 24, MCP 24, GateOpener 24 unchanged; gaps between frames unchanged | 26/26/27 |
| spacing 16 | unchanged: dummies stayed 26/26/27 | 40/40/41 |
| padding 8 (spacing unset) | unchanged | 32/32/33 (frame width identical to default) |
| padding 0 (spacing unset) | unchanged | 32/32/33 (identical) |
| reset (both keys removed) | dummies from the spacing 16 run kept width 40 until relaunched | 32/32/33 (baseline) |

Gaps between neighbouring frames (1 to 5 pt) are constant; spacing shows up as the width of each item, not as the gap between frames.
Other third-party items (iStat, WiFi Signal, VPN Switch, ...) did not change width during any step; widths of one item (KeepingYouAwake 22 -> 30 -> 17.5) varied independent of the setting (its own icon state), so it is not evidence either way.
The bar is saturated on this machine (many items system-overflowed and stacked at one x), so absolute x positions shifted when Bartender's own items came and went; only widths are comparable.

## Conclusion
- Spacing: applies **per app relaunch**. Not applied live to running apps (verified: nothing changed in 5 s). An agent restart (`killall MenuBarAgent`) was NOT needed and NOT performed (0 restarts). Logout was not tested.
- Padding: no change in any frame/width, even after relaunch. It only affects the selection highlight, which cannot be measured headlessly. A human visual check is required (see docs/testing.md "Spacing").
- Each app picks the value up when it (re)launches; apps that never relaunch keep their old spacing.

## End state
Both keys removed (`defaults -currentHost read -globalDomain ...` says the key does not exist). The ByHost GlobalPreferences plist is decode-equal to the pre-experiment backup. The com.apple.MenuBar.plist differs from the backup (third-party apps and Bartender rewrite positions continuously; no restart was performed by this experiment). Dummies stopped.
