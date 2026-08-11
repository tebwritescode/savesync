# SaveSync

**Automatic cross-device saves for
[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) - your save follows you
to every device you play on, stored on free space that belongs to you.**

Play on the desktop, close it, open the game on the laptop, press CONTINUE.
Your save is there. Sign in once and it looks after itself.

> Your saves live in your own storage, under your own account, and you can take
> them with you whenever you like.

## The storage is yours

Pick one at setup. Each is free, and each keeps SaveSync to a single corner of
your account.

| | where your saves live |
|---|---|
| **GitHub** | one secret gist, reached with the `gist` permission alone |
| **Dropbox** | one app folder of its own |
| **Your own server** | the Docker container in `server/`, on hardware you run |

Sign in on a second device and it finds the same storage by itself — your save
is waiting there.

## Your progress is protected

This is the part that matters most, so it is the part with the most care in it.

- **If two devices changed the same save, it stops and asks you**, showing both
  — *"here: 3 badges"* against *"cloud (Laptop): 5 badges"* — so the choice is
  always yours.
- **Whichever you pick, the other survives.** Ten past versions live on the
  device and ten in the cloud, and every replacement keeps the outgoing save
  first.
- **CONTINUE speaks up** when it could not reach your cloud, tells you when you
  last synced, and lets you play anyway. Offline is a normal way to play.
- **Save files only.** The upload set comes from reading your save slots, so
  your saves are exactly what travels.

## Snapshots, and why they are on

Every five minutes SaveSync quietly takes a **snapshot** — a copy of where you
are, kept beside your save. A crash costs you minutes instead of an evening,
and your save file stays exactly as you left it, so soft-resetting to re-roll a
starter or a legendary works the way it always has.

There is also a plain auto-save that writes the real save file on a timer.
That one ships off, and is yours to switch on if you want it.

## Install

1. Have Gen1Recomp set up with your own legally-obtained ROM.
2. Download the latest `savesync-<version>.zip` from Releases.
3. Launcher → MODS → **Import mod .zip**, then enable **SaveSync**.
4. Title screen → **SAVESYNC** → Set Up → GitHub, and type the code it shows
   you on any device with a browser. That is the whole setup.

On your other devices, repeat step 4 and sign in again. It finds your saves.

It asks for `network` to reach your storage, `filesystem` for its own backups,
and `engine_internals` to read and replace save slots through the engine's own
code — so the rules about where your progress lives stay in one place.

## Status

| | |
|---|---|
| GitHub, Dropbox and self-hosted storage | ✅ |
| Every save slot syncs, not just the selected one | ✅ |
| Conflict detection that stops and asks | ✅ |
| Ten local backups and ten cloud versions per save | ✅ |
| Snapshots every 5 min, restorable, save file left alone | ✅ |
| Stale-save warning on CONTINUE | ✅ |
| Works offline and retries later | ✅ |
| Google Drive | 🔜 |

## Running your own server

If you would rather your saves lived on hardware you own:

```sh
cd server
docker compose up -d
docker compose logs savesync    # your setup code is printed here
```

Paste that code into **SAVESYNC → Set Up → Use a setup code** on each device.
See [server/README.md](server/README.md).

## For developers

The sync protocol, storage layout and conflict rules are written up in
[docs/protocol.md](docs/protocol.md) — small enough to reimplement in an
afternoon, which is deliberate. Adding a storage backend is one file against a
four-function interface: [docs/providers.md](docs/providers.md). Tests live in
[tests/](tests/README.md).

## Licence

MIT. Original code and original artwork throughout; the mod ships and uploads
save data alone.

The sign-in client ids in `mod/providers.json` are public by design — the
GitHub device flow and Dropbox PKCE exist so a desktop app needs no secret —
but they are mine. If you fork this, register your own so your players get your
name on the consent screen and your own rate limit.
[docs/providers.md](docs/providers.md) walks through it.
