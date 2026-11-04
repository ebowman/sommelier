# Contributing

## Tools

- `make build` / `make test`: build and run the unit tests (`make build` also re-signs `mbprobe` with the app-group entitlement).
- `mbprobe` is the integration surface: `make probe ARGS="list"`, `ARGS="permissions"`, `ARGS="watch --seconds 30"`, and the
  actuating subcommands (`layout`, `cc-allowed`, `press`, `agent-restart`...). See the mbprobe section of the README.
  Do not use `swift run mbprobe`: it re-links an unentitled binary.
- `make dummy [ARGS="--count 3 --removal-allowed"]` starts MBDummy, a test app with configurable status items, so experiments
  never touch third-party items. `make dummy-stop` quits it.
- `make app-run` runs the app bundle binary with the terminal's Accessibility trust. Always set `SOMMELIER_LAYOUT_FILE=<path>`.
- Soak scripts (live, they drive the real menu bar): `scripts/soak-move.sh [--moves N] [--cycles N]` and
  `scripts/soak-events.sh [--relaunches N] [--toggles M] [--allow-respawn]`. See docs/testing.md.

## Invariants for live work

1. Quit Bartender before live tests (it fights every mechanism) and relaunch it afterwards: `open -a "Bartender 7"`.
2. Back up the two plists first: `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist` and
   `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`.
3. Never write the real `layout.json` during development; use `SOMMELIER_LAYOUT_FILE`.
4. Never `killall ControlCenter`.
5. **No UI state is shown as done without verification.** The UI renders observed state; desired state is shown separately as
   pending, in flight or failed. Every move/hide is checked against the real bar before it is reported as done.

## Release procedure

Requires a Developer ID Application identity in the keychain and notarization credentials: either `NOTARY_PROFILE` (a notarytool
keychain profile) or a gitignored `.env` with `API_KEY_ID` and `API_ISSUER_ID` plus
`~/.appstoreconnect/private_keys/AuthKey_<API_KEY_ID>.p8`. Never commit `.env`.

1. Set the version in `VERSION` (or pass `VERSION=x.y.z`).
2. `make release` : release build, `dist/Sommelier.app` signed (hardened runtime, timestamp, `Resources/Sommelier.entitlements`),
   `dist/Sommelier-<version>.dmg` signed, SHA-256 printed. `ALLOW_ADHOC=1` / `ALLOW_ADHOC_DMG=1` give a local-only ad-hoc build that cannot be notarized.
3. `make notarize` : submits with `notarytool --wait`, staples and validates on Accepted; on rejection the log is saved in `dist/` and the command fails.
4. Run the "Release smoke" section of docs/testing.md on the notarized build.
5. `CONFIRM_PUBLISH=1 make publish` : creates the GitHub release `v<version>` with the DMG and its SHA-256. Operator only;
   `scripts/publish-release.sh --dry-run` prints the command without creating anything.
