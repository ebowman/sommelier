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
