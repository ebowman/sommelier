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
2. `make release` : first removes stale notarization artefacts from `dist/` (`notarize-submit.json`, logs, zip, sha256, notes), then builds a release
   `dist/Sommelier.app` signed (hardened runtime, timestamp, `Resources/Sommelier.entitlements`) and `dist/Sommelier-<version>.dmg` signed, SHA-256 printed.
   `ALLOW_ADHOC=1` / `ALLOW_ADHOC_DMG=1` give a local-only ad-hoc build that cannot be notarized.
   CFBundleVersion is the commit count (`git rev-list --count HEAD`): commit everything BEFORE `make release`. Any later commit or rebuild
   changes the build number and means `make release` + `make notarize` again.
3. `make notarize` : makes TWO notarytool submissions, each waiting several minutes. First `dist/Sommelier.app` (zipped) is notarized and the ticket is stapled to
   the app itself (so a copied app launched offline still has its ticket); then the DMG is rebuilt around that stapled app (`SKIP_APP_BUILD=1 scripts/make-dmg.sh`),
   notarized and stapled. Resumable: an app that already passes `xcrun stapler validate` skips its submission, and a stapled DMG built from the stapled app is not resubmitted.
   On rejection the log is saved in `dist/` and the command fails. Afterwards `xcrun stapler validate` passes for both the app and the DMG.
4. Run the "Release smoke" section of docs/testing.md on the notarized build.
5. `CONFIRM_PUBLISH=1 make publish` : creates the GitHub release `v<version>` with the DMG and its SHA-256. Operator only. It refuses unless the tree has no tracked changes,
   the app inside the DMG has CFBundleVersion == the current commit count and CFBundleShortVersionString == `VERSION`, the embedded `SommelierGitCommit` (written into Info.plist by
   `build-app.sh`) equals `git rev-parse HEAD` and `SommelierGitDirty` is `0` (exact check; a DMG built before this key existed is refused with "predates the SHA check; rebuild"),
   the DMG is stapled and passes spctl, the app inside the DMG (mounted read-only) passes `xcrun stapler validate`, and the tag is new.
   Note: this repo currently has no `origin` remote configured, so `make publish` (and `--dry-run`) refuses until one exists (`git remote add origin git@github.com:<owner>/<repo>.git`).
   `scripts/publish-release.sh --dry-run` runs every check and prints the SHA-256, the tag and the `gh` command without creating anything.
   Shell tests for these checks: `make check-scripts`.
