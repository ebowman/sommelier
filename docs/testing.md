# Manual testing

## Developer launch trick
Run the app binary from a shell that has Accessibility trust, not via `open`:

    make app-run                         # logs to build/sommelier.log
    SOMMELIER_OPEN_PANEL=1 make app-run  # also opens the overflow panel 3 s after launch and logs its frame + entries
    pkill -x Sommelier

The engine pauses while Bartender runs, so quit Bartender first (`osascript -e 'quit app "Bartender 7"'`) or the
panel has no observed state. Relaunch it afterwards (`open -a "Bartender 7"`). A first launch creates
`~/Library/Application Support/Sommelier/layout.json`; delete it (and `.bak`) to start fresh.

## Overflow panel
1. Open: left-click the Sommelier item (Settings > General > Reveal mode = "Panel below menu bar"). A panel appears
   directly under the menu bar, right edge under the item, listing each hidden item as app icon plus name. The
   frontmost app must keep focus (no activation).
2. Close rules: click anywhere outside the panel; press Escape (closes the panel whenever it is open; the frontmost app is not activated); leave the union of
   panel and menu bar strip with the pointer for 400 ms; or stay idle for "Auto re-hide" seconds (0 = never).
   Clicking the Sommelier item again toggles it closed.
3. Show names off: Settings > "Show names in panel" shows icons only; hover shows the name as tooltip.
4. Many items: when the row is wider than 80 % of the screen it scrolls horizontally.
5. Empty state: with nothing hidden (or no hidden app running) the panel reads "Nothing hidden" with a disabled
   "Arrange…" button (enabled by gdu.19).
6. Multiple displays: click the item on each display; the panel opens on the display holding the item, clamped to
   that display's visible frame.
7. Inline mode: Reveal mode = "Inline" restores the old toggle that reveals the hidden section in the real bar.
8. Clicking an entry only logs `overflow click <key>` for now (forwarding arrives with gdu.17).

## Live hide detection

Bead sommelier-gdu.38, 2026-11-04, MBDummy only, Bartender 7 quit, entitled writer `scripts/ccset.swift` (built outside the repo). After a cfprefsd-notified hide
MenuBarAgent's hosted AX tree contains no Dummy-A/Dummy-B element at all, while the app's own `AXExtrasMenuBar` still reports on-bar frames
and `stale` stays false. `MenuBarScanner` therefore reports an app item as `isOnMenuBar=false`, `hidden=notHosted` (`mbprobe list` prints `hidden=notHosted|parkedFrame`, `list --json` has a `hidden` key) when
ALL hold: the owner runs, the frame says on-bar, the item has an AX identifier (description-only items must also be unjoined), it was seen hosted by name in an earlier read
(`seenHostedKeys`; never-seen items stay frame-ruled so an app whose hosted element is named differently can never loop as "hidden"), and a COMPLETE hosted read has no element of that name.
Incomplete reads keep the frame rule, except that an item already proven hidden stays hidden until a read shows it hosted again.

**Detection is reported by the FIRST COMPLETE full scan after the write.** The bound is the duration of a full scan (about 1.1-3 s here) plus read completeness, not the detection logic.
A first scan whose hosted read is incomplete (failed AX reads; seen once with 16 failed reads) reports the OLD state (on-bar), so a verifier must poll until a complete
read and must not trust a single scan. Do not assume sub-second detection.

Procedure: `./ccset ie.boboco.mbdummy 0`, then `mbprobe list --json` in a loop every 0.5 s for 5 s (scan-bound).
| Step | Observation |
|---|---|
| write `isAllowed=0` (ccset call itself) | 12-15 ms |
| hide: write -> first complete scan reporting both dummies `notHosted` | implementer runs +0.95 s, +1.14 s; reviewer runs +1.59 s, +3.07 s, +4.13 s (range 0.95-4.13 s). One reviewer first scan (+2.54 s) was incomplete (16 failed reads) and reported on-bar. |
| hide, following scans | stay `notHosted` (sticky rule; before it, one incomplete scan flipped back to on-bar) |
| show (`ccset ... 1`) -> first scan reporting both on-bar | implementer +1.5 s; reviewer +1.11, +1.65, +1.90 s |
| non-dummy on-bar order, before vs during hide vs after show | identical (18 items; only the "64%" -> "65%" readout title changed) |
| fast path (`list --fast`, one-shot process, 0.3 s hosted deadline) | reports `notHosted` only on complete reads, which are intermittent on this machine (first one at +4.05 s in one run). It is not a bounded-latency signal. |
