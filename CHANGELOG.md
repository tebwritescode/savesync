# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-08-11

### Added
- **Auto save.** SaveSync -> Auto save -> 3 / 5 / 10 / 15 min. Writes the
  game's own save on a timer, and syncs like any other save.
  - **Off by default, deliberately.** In Gen 1, saving is part of how people
    play: soft-resetting to re-roll a starter or a legendary works *because*
    the game only writes when told, and an autosave between the encounter and
    the reset would destroy that silently.
  - **Every autosave takes a backup first**, tagged `auto`, so one that lands
    at the wrong moment is undoable from Restore Previous Save.
  - **Only writes when settled in the free-roam overworld** -- never during a
    battle, menu, shop, cutscene, warp, or mid-step. The gate is the engine's
    own `Zoom.gateOK` rather than a second opinion about what "in the
    overworld" means; the fallback for a build that moved it is the same
    predicate, not a looser one. A save that comes due at a bad moment is
    deferred, not skipped.
  - A veto from the `save.write` hook backs off for a minute instead of
    retrying every frame.
  - The row appears whether or not the cloud is set up: autosave is worth
    having on a machine that will never be connected.
- Auto save and Restore Previous Save are now reachable before setup, so an
  unconnected install is still useful.

## [1.1.0] - 2026-08-11

### Added
- **Every save file syncs, not just the selected one.** Slots are independent
  playthroughs; a player with three Red files and a Yellow file has four, and
  only the active one was being synced. `readAllLocal` now walks every
  registered slot of every version.
- Uploads now leave a local backup too, tagged `sent`. Previously backups were
  only written when a save was *displaced*, so a player who only ever used one
  device had an empty Restore Previous Save list -- nothing overwrote them, so
  nothing was ever kept. Duplicate bytes are skipped so the ten slots are not
  churned by repeated syncs.
- Credentials refreshed during a conflict resolution or a restore are now
  persisted, not just those refreshed during a normal cycle.

### Fixed
- **A download could overwrite an unrelated playthrough.** `Store.apply` wrote
  into whichever slot happened to be *selected*, so a save arriving for
  playthrough X landed on top of playthrough Y. It now finds the slot holding
  that playthrough by its id, creates a new slot for one this device has never
  seen, and never steals the active selection from a save in progress. The
  mutation test for this reports a 4-badge file replaced by an unrelated
  20-badge one.

### Fixed -- transport and Dropbox setup
- **Every Dropbox call would have failed on Windows.** Requests were assembled
  as a curl command line quoted with `HostShell.quote`, which on Windows
  *deletes* double quotes from an argument rather than escaping them (cmd.exe
  has no safe escape it could use). Dropbox passes its file arguments as JSON
  in a `Dropbox-API-Arg` header, so every upload and download would have gone
  out malformed. All arguments now go through a curl config file, which has
  its own quoting rules, leaving only a path we chose exposed to a shell.
- A Dropbox permission the app was never granted returns a 401 that looks
  exactly like an expired token. It was triggering a pointless refresh and
  then reporting "sign-in expired" at someone whose sign-in was fine; it is
  now detected and names the missing scope.
- `docs/providers.md` omitted `files.metadata.read` from the Dropbox setup.
  Without it `list()` fails — the first call of every sync — so setup would
  have looked complete and then never worked.

### Added -- verification
- `tests/e2e.test.js`: the whole stack with nothing stubbed between the sync
  engine and the socket, running the HTTP worker's verbatim source against
  real curl and a real server. Verified on Windows and Linux.
- GitHub client id wired in and verified against the live device-flow
  endpoint; Dropbox app key wired in and verified against the live token
  endpoint (a real key answers `invalid_grant` to a bogus code, an unknown
  one answers `invalid_client`).
- `tests/run.lua` now parses `providers.json` and asserts both client ids are
  present, so a stray comma or a blanked id fails a test rather than failing
  sign-in for everyone with no other symptom.

## [1.0.0] - 2026-08-10

First release.

### Added
- Automatic cross-device save sync for Gen1Recomp, as a mod API 2 mod.
- Provider layer with a four-function interface (`link` / `read` / `write` /
  `list`), so a storage backend can be replaced without touching the sync
  engine.
  - **GitHub** — OAuth device flow, `gist` scope only, one secret gist per
    player. Signing in on a second device finds the same storage with no code
    to copy.
  - **Dropbox** — PKCE with no redirect, App Folder scope, refresh-token
    renewal on 401.
  - **Self-hosted** — the Node backend in `server/`, paired with a setup code.
  - **Google Drive** — interface stub, with the verification and device-flow
    limits that block it written down.
- Three-hash conflict detection: a save changed on two devices independently
  stops sync and asks the player, and is never resolved by timestamp.
- Ten local backups and ten cloud history versions per save; every path that
  replaces a save backs the outgoing one up first.
- Setup codes (`SSYNC1.<base64url>`) for pairing, via clipboard or a
  `savesync/setup-code.txt` fallback on devices without one.
- In-game SaveSync screen on both the title menu and the Start menu.
- Downloads are held back while a session is live, because a running game
  would write the old save back out over them.
- Async HTTP on retiring worker threads, so no frame blocks and closing the
  window never waits on the pool.
- Self-hosted backend: Node standard library only, Docker + Compose, atomic
  batch writes, per-token storage isolation.
- Tests: codecs and the decision table, a two-device conflict scenario over a
  shared cloud, and an over-HTTP test of the backend.
