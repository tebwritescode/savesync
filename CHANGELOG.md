# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

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
