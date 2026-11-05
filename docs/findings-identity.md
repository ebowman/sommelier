# Item identity and the MenuBarAgent `ownerKey` rule (sommelier-gdu.4)

Measured 2026-11-03 on macOS 27.0.1. Store: `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`
-> `TrailingItemPreferredPositions`. Item ids there are `status:<ownerKey>::<autosaveName>` and `module:<Name>`.

## Result: the ownerKey rule

> `ownerKey` is the app's **bundle identifier** when the app runs from an *installed* location, and the **executable
> (process) file name** otherwise. It is never the code-signing identifier, CFBundleName, localized name or bundle directory name.

"Installed" as observed: `/Applications`, `/System/...`, login-item helpers inside such bundles, and registered helpers under
`~/Library/Application Support` (iStat Menus Menubar.app). "Not installed": a build directory, `~/src`, `~/Applications`,
App Translocation paths, bare executables.

Implemented as `OwnerKeyRule.candidates(for:)` (SommelierCore): returns `[bundleID, executableName, ...]` for installed paths and
`[executableName, bundleID, ...]` otherwise, followed by bundle dir name, CFBundleName, localized name, signing id. Because the
installed-location test is empirical, the resolver never trusts the order alone: every candidate that has autosave names is scored
(identifier matches, then agreement of store values with on-bar x order) and ties go to rule order.

### Evidence 1: controlled experiment (fresh ad-hoc dummy apps, executable / bundle dir / CFBundleName / bundle id all different)

| Run | Location | bundle id | exe | dir | CFBundleName | Key written by MenuBarAgent |
|---|---|---|---|---|---|---|
| MBDummyy | `build/` (repo) | ie.boboco.mbdummyy | MBDummyyexe | MBDummyydir | MBDummyyname | `status:MBDummyyexe::Dummy-A` |
| MBDummyz | `~/Applications` | ie.boboco.mbdummyz | MBDummyzexe | MBDummyzdir | MBDummyzname | `status:MBDummyzexe::Dummy-A` |
| MBDummyw | `/Applications` | ie.boboco.mbdummyw | MBDummywexe | MBDummywdir | MBDummywname | `status:ie.boboco.mbdummyw::Dummy-A` |

Same binary, same signature kind (ad-hoc), only the location changed: `/Applications` -> bundle id; elsewhere -> executable name.
Entries are written lazily (seconds after the item appears, not on a drag). The three test bundles were deleted afterwards;
their store entries (`MBDummyyexe::Dummy-A`, `MBDummyzexe::Dummy-A`, `ie.boboco.mbdummyw::Dummy-A`) remain in the store (written by
MenuBarAgent, not by us; harmless). Copying MBDummy itself to `~/Applications` kept using `MBDummy::` (name == exe).

### Evidence 2: running apps on this machine vs the store (candidate columns: bid = NSRunningApplication.bundleIdentifier,
loc = localizedName, exe = executableURL.lastPathComponent, dir = bundle dir minus .app, cfn = CFBundleName, cs = `codesign -dv` Identifier)

`x` = equals the ownerKey used by the live items; `-` = not equal.

| App | Path class | ownerKey in store | bid | loc | exe | dir | cfn | cs |
|---|---|---|---|---|---|---|---|---|
| MBDummy | `build/` | `MBDummy` | - | x | x | x | x | - |
| GateOpener | `~/src/gateopener/` | `GateOpener` | - | x | x | x | x | - |
| FloTile (now) | `/Applications` | `ie.boboco.FloTile` | x | - | - | - | - | x |
| FloTile (old key, dev build) | `~/src/.../Debug` | `FloTile` | - | - | x | x | x | - |
| iStat Menus Menubar (live) | `~/Library/Application Support` helper | `com.bjango.istatmenus.status` | x | - | - | - | - | x |
| iStat Menus Menubar (old key, translocated) | AppTranslocation | `iStat Menus Menubar` | - | x | x | x | x | - |
| KeepingYouAwake | `/Applications` | `info.marcel-dierkes.KeepingYouAwake` | x | - | - | - | - | x |
| 1Password | `/Applications` | `com.1password.1password` | x | - | - | - | - | x |
| Bartender 7 | `/Applications` | `com.surteesstudios.Bartender` | x | - | - | - | - | x |
| WiFi Signal | `/Applications` | `signal` (bundle id is literally `signal`) | x | - | - | - | - | x |
| Fantastical Helper | login item | `85C27NK92C.com.flexibits.fantastical2.mac.helper` | x | - | x | x | x | x |
| Hazel Helper | login item | `86Z3GCJ4MF.com.noodlesoft.HazelHelper` | x | - | x | - | x | x |
| MCP Maestro | `/Applications` | `com.king.cto.mcpmaestro` | x | - | - | - | - | x |
| Airmail2Hookmark (ad-hoc, sandboxed) | `/Applications` | `com.airmail2hookmark.app` | x | - | - | - | - | x |
| Alfred 5 | `/Applications` | `com.runningwithcrayons.Alfred` | x | - | - | - | - | x |
| SystemUIServer, Script Menu, TextInputMenuAgent | `/System` | bundle id (`com.apple.systemuiserver`, ...) | x | - | - | - | - | x |

Across the 40 running apps with items: 34 apps use the bundle id (all installed), 2 live apps use the executable name (MBDummy,
GateOpener: both outside `/Applications`), 1 app (Dropbox) had no order-store entry (legacy defaults only). Signing kind does not
matter: ad-hoc Airmail2Hookmark (installed) -> bundle id; Developer-ID GateOpener (in `~/src`) -> exe name. Sandboxing does not
matter. The `cs` column always equals `bid` except where noted, so it cannot explain any non-bundle-id case (MBDummy, GateOpener:
cs == bid yet key == exe).

Control Center modules are not owned by an app: `module:<Name>` (e.g. `module:WiFi`, `module:Clock`, `module:AudioVideoModule`). Their
AX identifiers are `com.apple.menuextra.<lowercased name>` (`clock`, `audiovideo`, `controlcenter`); the resolver maps by normalizing
the last identifier component and the module name (strip `Module`, lowercase). `com.apple.menuextra.controlcenter` has no `module:`
entry in this store and stays `heuristic`.

### Stale duplicate keys (why scoring, not just rule order)

The store keeps old keys forever: `status:FloTile::Item-0` (731) and `status:ie.boboco.FloTile::Item-0` (157);
`status:iStat Menus Menubar::...` (8 names, old translocated launch) and `status:com.bjango.istatmenus.status::...`. The live
iStat set is identifiable because its values decrease monotonically with on-bar x (weather 553 at x=1286 ... time 99 at x=1721); the
old set does not (weather 1469, cpu 602, ...). A single-item app with two keys (FloTile) cannot be told apart by order evidence alone;
rule order (installed -> bundle id) decides, and `mbprobe keys` shows both.

### Control Center `trackedApplications` correlation

`ControlCenterTrackedAppsStore` (`mbprobe cc-allowed list`) keys are `{bundle: id}` or `{adhocBinary: {relative: url}}`. Every live
non-bundle-id owner has an `adhocBinary` menu item location pointing at its non-installed path: MBDummy
(`.../sommelier/build/MBDummy.app/Contents/MacOS/MBDummy`), GateOpener (`~/src/gateopener/GateOpener.app/...`, plus three build-dir
variants), Sommelier (`build/Sommelier.app`), FloTile dev build (`~/src/FlöTile/.build/.../FloTile`). So `adhocBinary` is a good
*necessary* signal for "not installed". It is NOT sufficient: the iStat helper (installed, bundle-id keyed) also has an
`adhocBinary` location (its `~/Library/Application Support` path). The tracked-apps file is therefore not used for the rule.

## Identity resolution

`IdentityResolver.resolve(snapshot:)` returns `[ResolvedItem]` (item, key, confidence) in snapshot order. Confidence:

* `exact`: store/defaults key AND an item attribute that is not a frame supports it: AXIdentifier equals the autosave name (iStat,
  Dummy, Bartender, Hookmark-style apps), or one item + one name where the item carries an AXIdentifier and is not stale.
* `inferred`: real store key but the pairing rests on an assumption: single item + single name without an identifier; or N items +
  N names paired by order (below).
* `heuristic`: `heuristic:<bundleID>::<fingerprint>#<ordinal>`; also unmapped agent-hosted names.

Per gdu.7: frame evidence never produces `exact`; identifier-less items are `inferred` at best (the fast scan can mislabel owners of
identifier-less items right after a move, so the actuator must confirm those with a full scan).

Order pairing assumption: the store value is the distance from the trailing (right) edge, so **bigger = further left**. Names sorted
by value descending are zipped with on-bar items sorted by x ascending. Applies only when all remaining items are on the bar, counts
are equal, and the values are distinct. Parked items have no meaningful x, so they are never paired (-> `heuristic`; this affects
ToothFairy, whose two hidden items have `Item-0`/`Item-1` in the store). The store holds extra names for some apps (iStat has
`AudioVideoModule` under its own key; CleanMyMac has two names at 731), so equal counts are required.

Agent-hosted-only items become `.module(<store module name or AXIdentifier or description>)`; `_NS:<n>` identifiers (per-launch
AppKit numbering of the frontmost app's menus: File, Edit, ...) are ignored.

Determinism: heuristics use only AX attributes (title digits masked) plus left-to-right ordinals by (x, y, discovery index). Identical
parked items share a frame, so their ordinals depend on discovery order (not stable across scans in principle; not seen so far).

## Results on this machine (`mbprobe list`)

51-58 items depending on which app is frontmost (its menus appear as parked agent-hosted items): 10 exact, 37 inferred, 4 heuristic
(2 ToothFairy parked items, the Control Center module, one nameless system item) plus up to 7 heuristic app-menu items (Apple, File,
Edit, ...; not status items). Keys identical (as a set, and per item) across two consecutive full scans and a `--fast` scan. iStat
resolves to `status:com.bjango.istatmenus.status::com.bjango.istatmenus.<module>` (exact, 8/8).

## Commands

* `mbprobe list` shows a key column and marker (`=` exact, `~` inferred, `?` heuristic); `--json` adds parallel `keys` and `keyConfidence` arrays.
* `mbprobe keys <ownerKey|bundleID>` prints, per matching owner key, the autosave names with store and legacy values.

## Main-menu entries in the agent tree (gdu.29)

MenuBarAgent can mirror the frontmost app's MAIN menu into its AX tree (Apple, the app-name menu, File, Edit, Format, View, Window, Help). They
reach the scanner as agent-hosted elements owned by `com.apple.MenuBarAgent` and, before gdu.29, became `heuristic:com.apple.MenuBarAgent::_NS:<n>`
parked entries (w=0, x=0) that change with the front app.

Evidence (`docs/evidence/ax-b-drag-unrelated.txt` and siblings, 190 such lines, always the same shape):
`AXMenuBarItem sub= title='File' desc='' id='_NS:450'` at x=0 y=30 w=0 h=0. The iStat entry is `title='iStat Menus Menubar' id='_NS:433'` in the
same shape: it is iStat's app-name menu (iStat was frontmost then), not a status item, so the same rule covers it; no title special case.
All 266 hosted `AXMenuBarItem`s in the evidence set that are status items carry subrole `AXMenuExtra`; the only ones without it are these
main-menu entries. Hosted status items in the live tree today are `AXMenuBarItem/AXMenuExtra` (Control Center modules) or `AXButton`.

Discriminator (structural, not frame based): role `AXMenuBarItem` AND subrole != `AXMenuExtra`. `LiveAccessibilitySource.collect` sets
`AXElementInfo.isMainMenuEntry`; `MenuBarScanner.droppingMainMenu` removes such elements (and timed-out copies of them) from every hosted read
before anything else (carry-forward, noise, completeness, `lastHosted`). A timed-out group made only of such entries is not counted as a failed read.
The width <= 1 noise rule (gdu.51/54) is unchanged and still applies to everything else (a genuine item that is briefly 0 wide is kept as before).

Persisted cache: `ScanCache` stores no role, so on load `lastHosted` records with an empty 0x0 frame, a title and no description are discarded
(`AXElementInfo.looksLikeMainMenuRecord`). Per-app extras and the key sets never contained these elements.

Limitation: the live agent did not mirror the main menu during the gdu.29 session (12 dumps, Finder/Terminal/TextEdit/Safari/Mail, 0 occurrences),
so the live "before" could not be reproduced; the rule rests on the recorded evidence plus the unit tests.
