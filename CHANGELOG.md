# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [1.9.1] - 2026-08-12

### Fixed
- **"B: skip" now skips.** While the boot check was running, the screen offered
  B to skip -- and B cancelled CONTINUE instead, dropping the player back on
  the title menu to press CONTINUE again. Someone pressing skip has just said
  they do not want to wait for the cloud, so B now loads the save without the
  check, which is what the word means. The footer reads `B: skip and play`.
  - On the *warning* screen B is still a plain cancel: there are explicit
    `Play anyway` and `Back` rows to choose between, so B has an obvious
    meaning there.

## [1.9.0] - 2026-08-12

### Added
- **Restore lists are paged**, four at a time with a `More (2/3)` row, rather
  than one long ribbon to drag a cursor through on a d-pad. Someone picking a
  restore point wants to see a handful and step. The More row **wraps**, so
  one button walks the whole list and nobody strands themselves on the last
  page.
- Picking an entry is tested against the row itself rather than its index on
  screen, because the bug a paged list invites is restoring the save one page
  off from the one you chose.

## [1.8.1] - 2026-08-12

### Fixed
- **The restore list froze the game.** Reported from a device that had to be
  force quit. Each row's label looked up which slot a save belonged to, and
  that lookup read and Lua-decoded *every save slot on disk* -- while
  `currentItems()` runs three times a frame. Ten backups across three slots
  came to roughly ninety full save decodes per frame.
  - Labels are now built once, when the list is built, from a single pass over
    the slots. The per-frame path only reads a string.
  - A test drives thirty frames of the restore list and asserts it touches the
    disk **zero** times. Put the lookup back in the label and it reports 600.
- **Older cloud objects still restore.** Payloads gained a `b64:` prefix and
  history filenames gained a timestamp; anything written before those changes
  is still listed and still restorable, now with a test that writes an
  old-shape entry by hand and restores it. History outlives the code that
  wrote it, and refusing the old form would turn a player's existing backups
  into nothing on the day they finally needed one.

## [1.8.0] - 2026-08-12

### Fixed after release
- **The v1.8.0 zip carried a 1.7.1 manifest.** The version was bumped in the
  source *after* the mod had been copied into the engine checkout, so `modkit
  pack` faithfully packaged the stale copy: the launcher offered the update,
  installed it, and then reported the old version, with no error anywhere.
  Both release assets were rebuilt and replaced.
- `tools/release.sh` now makes that impossible. It copies **after** checking
  the source manifest, then reads the version back **out of the finished zip**
  and refuses to hand over an artifact that disagrees with the version asked
  for -- verifying the artifact rather than the intent. It also checks
  `main.lua` sits at the archive root, which the loader requires.

### Added
- **SaveSync lives in OPTIONS now**, with its state in the value column
  (`ON` / `SYNCING` / `OFFLINE` / `ASK`), so you can see whether your save is
  safe without opening anything. OPTIONS is on both the title screen and the
  in-game Start menu, so one row replaces two — and the Start menu goes back
  to the length the vanilla game keeps it.
- **A save you chose asks whether to send it up now.** *"Saved. Send to the
  cloud now?"* — Sync now / Later / Stop asking.
  - Only for saves the **player** chose. Autosaves and snapshots never prompt,
    which is the whole point of them.
  - It waits for the save script to finish and the world to settle before
    appearing, so it never lands on top of the game's own text box.
  - **Later cancels nothing** — the normal debounced upload still happens. All
    "Sync now" buys is *now*, which is what someone about to close the lid or
    pick up another device actually wants.
  - Toggleable from the prompt itself and from `Ask on save` on the SaveSync
    screen.

## [1.7.1] - 2026-08-12

### Fixed
- **The mod would not load on iOS at all.** `os.getenv` is absent there, and
  an unguarded call to it -- a developer convenience for overriding an OAuth
  client id -- threw while the mod was loading, so every iOS player got
  `attempt to call field 'getenv' (a nil value)` in the mod manager instead of
  the mod. It cost nothing on desktop and everything on a phone. The read is
  guarded, and a test now scans every mod source for unguarded `os.getenv`,
  `os.execute`, `io.popen` and `os.tmpname`, because the engine itself uses
  them freely and the rule only applies to the mod.
- **EXIT is the bottom of the title menu again.** The SAVESYNC row was
  appended, which put it underneath the way out. It is now anchored before
  `EXIT GAME`, matched on the engine's localised string so translated builds
  order correctly too.
- **Restore entries say what they are.** They read `RED 1 08-12 00:09` -- game,
  slot, then when it was taken -- rather than `version 3`, which answered none
  of the three questions a player has. Cloud history filenames now carry their
  timestamp; the older shape is still read, so versions saved by an earlier
  build stay restorable.
  - The game version leads because Gen 2 is on the horizon and `RED 1` will
    stop being the only thing on the list.

## [1.7.0] - 2026-08-11

### Added
- **Save files** on the menu: every slot on the device with the state sync has
  it in — `RED 1 synced`, `RED 2 waiting`, `RED 3 conflict`. A single global
  "last synced" line says nothing about slot three, which is exactly the slot
  a player worries about.
- Picking a slot opens the backups for **that save**. One flat list of every
  backup on a multi-slot install is a wall of timestamps with no way to tell
  whose they are.

### Changed
- **Ready for Gen 2.** The version list is read from the engine's own
  `GameVersion.VERSIONS` registry rather than naming Red, Blue and Yellow in
  this mod. Nothing here is Gen 1 specific — a save is bytes, a slot is a
  slot, and the sync key is `<version>-<playthroughId>` — so an engine that
  registers Gold or Crystal is synced by this code unchanged. Tested by
  adding a fake Gen 2 entry to the registry and asserting it syncs; hardcode
  the list again and that test fails.
- Versions are walked in sorted order, so a cycle reports and uploads in the
  same order every run.

## [1.6.1] - 2026-08-11

### Changed
- One description, everywhere. The README pitch, the GitHub and Gitea repo
  descriptions, the mod manifest and both index summaries now carry the same
  sentence, so a player meets the same words wherever they first find it.
- A plain hyphen rather than an em dash in that sentence: the manifest text
  can reach the in-game font, and the Gen 1 charmap has no em dash to draw.

## [1.6.0] - 2026-08-11

### Added
- **CONTINUE warns you before loading a save it could not verify.** The boot
  sync already ran at the title screen; now its result is visible. If the
  cloud could not be reached, CONTINUE asks — *"Could not reach your cloud
  saves. This save may be older than another device."* — shows when you last
  synced, and offers **Play anyway**.
  - It is a question, never a wall. Offline play is a first-class case, and a
    mod that stops someone playing their own game on a train has failed worse
    than one that loads a slightly old save.
  - When the check comes back clean it does not appear at all, so the common
    path is untouched.
  - While the check is still in flight it waits up to 6 seconds, and B skips
    the wait. If the answer arrives mid-wait and is good, it gets out of the
    way without making anyone acknowledge anything.
  - Matched against the engine's own localised `Strings("CONTINUE")` rather
    than the literal word: a safety net that only protects English speakers
    is not one.
  - This does not prevent data loss — the three-hash rule already does that,
    turning a played-stale save into a conflict rather than an overwrite. It
    prevents the *wasted evening* that a conflict costs.
- The official SaveSync icon, resized to 512px (repo) and 256px (index cards)
  with BOX filtering, which keeps pixel art flat where LANCZOS rings.

### Fixed
- **Dropbox missing-permission errors were unreadable.** The detector only
  looked for a 401 carrying a JSON `missing_scope` object, per the docs.
  Checked live: Dropbox actually answers **400 with plain text** on the file
  endpoints, so a player with an under-permissioned app got a bare
  `Dropbox said HTTP 400`. It now extracts the scope name from the real
  response and says which box to tick — verified against Dropbox's literal
  bytes.

## [1.5.0] - 2026-08-11

### Added
- First public release. The manifest now carries `github` and `homepage`, so
  the launcher can offer in-game updates and "Other versions" from the
  repository's releases -- a listed mod that cannot self-update is a mod
  every player has to reinstall by hand.

## [1.4.1] - 2026-08-11

### Fixed
- **The screen drew on top of itself.** Reported from a screenshot: status
  text and menu rows overlapping, and rows spilling past the border. The
  header flowed with its content while the rows were clamped *upward* to fit,
  so once the status wrapped onto several lines the rows were positioned
  above where the text ended. Header and rows now have fixed budgets --
  4 header lines from y=22, 5 rows from y=72 -- and anything longer is cut
  there and reachable in full through the reader.
- The cursor window and the number of rows actually drawn are now one
  constant. They were two, which would have scrolled the cursor to a row the
  player could not see.
- The layout constants are asserted by a test: the header cannot reach the
  rows, the rows stay inside the border, and the cursor window matches. No
  drawing test can catch this without real font sheets, so the geometry is
  checked instead of the pixels.

### Added
- A repo icon: a floppy disk with a cloud, 32x32 pixel art in the DMG green
  palette the game itself renders in.

## [1.4.0] - 2026-08-11

### Added
- **Scrollable text.** Any message too long for the screen now offers a
  `Read full message` row that opens a full-screen reader: UP/DOWN scroll, B
  returns, a drawn up-arrow and the vanilla more-arrow mark both ends.
  - It is a **separate view** on purpose. UP/DOWN already drive the menu
    cursor, so scrolling text on the same screen means one of the two
    silently stops working depending on where the cursor sits -- which reads
    as a broken game. Alone on its own screen, UP/DOWN can only mean one
    thing, and the reader takes the d-pad before the menu ever sees it.
  - The row only appears when the text genuinely overflows; a row that is
    usually inert is worse than no row on a 160x144 screen.
  - This closes the loop on the field bug: `GitHub said HTTP 400` drew as
    `GitHub said HTTP 40`, and 400 could not be told from 404.

## [1.3.0] - 2026-08-11

### Fixed
- **Saves never uploaded to GitHub. Root cause: a save is bytes, not text.**
  Reported from the first real install: sign-in worked, the gist got its
  README, and no save ever arrived. The engine serialises saves with Lua's
  `%q`, which passes bytes >= 0x80 through raw, so `save.lua` need not be
  valid UTF-8 -- and the sync layer put those bytes straight into a JSON body.
  Verified live against the real API: a raw `0xE9` gets
  `400 {"message":"Problems parsing JSON"}`; valid UTF-8 gets 200. Payloads
  are now base64 behind a self-describing `b64:` prefix, applied at the sync
  layer so every provider is fixed at once, with a raw fallback on read so
  history written by an older build still restores.
- **The self-hosted server had the same defect, silently.** `raw.toString('utf8')`
  rewrites an invalid byte as U+FFFD, so it would have stored a corrupted save
  and reported success. It now decodes with `fatal: true` and answers 400.
- Every test fixture was pure ASCII, which is why 250+ checks passed while the
  real thing failed on first contact. Added a binary torture fixture (lone
  `0xE9`, valid multi-byte UTF-8, NUL, DEL, `0xFF`, quotes, backslash,
  newline, tab) that must round-trip byte-identically device-to-device, and an
  assertion that nothing non-ASCII ever reaches the wire.
- `Content-Type: application/json` on GitHub requests. Kept as hardening --
  live testing showed real GitHub returns 200 without it on both POST and
  PATCH, so it was **not** the cause of the above.

### Added
- `tests/github.test.js`: a fake GitHub gist API (device flow, create, read,
  patch-with-deletes, list) driving the real provider through the real HTTP
  worker, so the provider is no longer untested for want of credentials.

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
