# SaveSync for Gen1Recomp

Automatic cross-device saves for [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp),
using **free storage that belongs to the player**, not to the mod author.

```
SAVESYNC
Connected  ✓
Last synced: just now

  Sync Now
  Pair Another Device
  Restore Previous Save
```

Play on the desktop, close it, open the game on the laptop, press CONTINUE —
your save is there. Nobody hosts anything for anyone else, there are no
accounts to create, no subscriptions, no server for the mod author to run.

---

## For players: setting it up

**SaveSync → Set Up → GitHub → type the code it shows you → done.**

That is the whole thing. The game shows an eight-character code and a web
address; you type the code on any device with a browser (your phone is fine),
and the game finishes on its own.

**On your second device: SaveSync → Set Up → GitHub → sign in again.** It
finds the same storage automatically. There is no code to copy between
devices unless you want one.

After that it looks after itself:

| when | what happens |
| --- | --- |
| you save in-game | uploaded a few seconds later |
| you start the game | checks for a newer save and pulls it down |
| you have no internet | keeps playing normally, retries later |
| two devices changed the same save | **stops and asks you** — see below |

### It will not eat your progress

This is the part the mod takes seriously.

* Every version of every save is kept — ten on the device, ten in the cloud.
* Nothing is ever replaced without the outgoing save being backed up first.
* If two devices changed the same save while apart, sync **stops**. It shows
  you both — "this device: 3 badges, 4:12" / "cloud (Laptop): 5 badges, 6:40"
  — and waits. Whichever you pick, the other one is still recoverable from
  **Restore Previous Save**.
* A save is never chosen by clock time. Clocks are wrong, and picking the
  "newer" one is how naive sync loses playthroughs.

### What gets uploaded

Save files. That is the entire list — the same `save.lua` the game already
writes, a small manifest next to it, and previous versions of it. A save is
about 32 KB.

**ROMs and game content are never uploaded.** The upload set is built by
reading the engine's save slots, so there is no path by which anything else
could be included.

---

## Where the saves actually live

Pick one at Set Up. The mod does not care which, and can change later.

| provider | what you need | notes |
| --- | --- | --- |
| **GitHub** *(recommended)* | a GitHub account | A secret gist in your own account. Free, no size limits at this scale, versioned by git. Only the `gist` permission is requested — the mod cannot see your repositories. |
| **Dropbox** | a Dropbox account | One folder (`Apps/Gen1Recomp SaveSync`) inside your Dropbox. The mod cannot see anything else in it. |
| **My own server** | Docker | The tiny backend in [`server/`](server/). One `docker compose up`, paste the code it prints. |
| Google Drive | — | Not shipping yet, and [`mod/src/providers/gdrive.lua`](mod/src/providers/gdrive.lua) explains exactly why. |

If today's free provider ever disappears, adding a new one is one file
against a four-function interface — no part of the sync engine changes. See
[docs/providers.md](docs/providers.md).

---

## Installing the mod

Copy [`mod/`](mod/) into your Gen1Recomp `mods/` folder as `savesync`, and
enable it in the mods manager:

```sh
cp -r mod /path/to/gen1recomp/mods/savesync
```

Requires Gen1Recomp mod API 2. Desktop (Windows, macOS, Linux) needs `curl`,
which all three ship. Android without `curl` degrades to read-only rather
than failing.

### Client ids, if you fork this

Sign-in needs one **public** OAuth client id per provider, which a
distribution registers once and everybody's copy shares. They are not
secrets — the GitHub device flow and Dropbox PKCE exist precisely so a
desktop app needs no client secret — but they are per-distribution, so a fork
should register its own rather than borrow this one.

| provider | state in [`mod/providers.json`](mod/providers.json) |
| --- | --- |
| GitHub | **set** — device flow verified against GitHub |
| Dropbox | empty; picking Dropbox says "not configured" until an app key is added |
| self-hosted | needs no client id, works on a fresh checkout |

The registration walkthrough for both is in
[docs/providers.md](docs/providers.md) and takes about two minutes each.

---

## Self-hosting the backend

```sh
cd server
docker compose up -d
docker compose logs savesync      # your setup code is printed here
```

Paste that code into **SaveSync → Set Up → Use a setup code** on every
device. Full guide, including free places to run it: [server/README.md](server/README.md).

---

## How it works

```
 in-game SAVE ──► save.writing event ──► debounce 4s
                                            │
 title screen  ──► game.ready event ────────┤
                                            ▼
                                     ┌─────────────┐
                                     │ sync engine │  compares three hashes
                                     └──────┬──────┘
                    upload / download / STOP AND ASK
                                            │
                                     ┌──────▼──────┐
                                     │  provider   │  read / write / list
                                     └──────┬──────┘
                          GitHub gist · Dropbox · your server
```

The safety rule in one paragraph: the mod remembers the last state this
device and the cloud were known to agree on. If only the local file has moved
away from it, this device is ahead — upload. If only the cloud has, the other
device is ahead — download. If **both** have, no automatic answer is correct,
so it stops. That function is
[`Sync.decide`](mod/src/sync.lua), and it is tested exhaustively.

| file | what it owns |
| --- | --- |
| [`mod/main.lua`](mod/main.lua) | engine wiring: menu rows, the per-frame pump, the save event |
| [`mod/src/sync.lua`](mod/src/sync.lua) | what to upload, when, and when to refuse |
| [`mod/src/store.lua`](mod/src/store.lua) | reading and replacing save slots; backups; config |
| [`mod/src/providers/`](mod/src/providers/) | one file per cloud |
| [`mod/src/op.lua`](mod/src/op.lua) | coroutine-based async, so no frame ever blocks |
| [`mod/src/http.lua`](mod/src/http.lua) | HTTP on worker threads, via the engine's own transport |
| [`server/server.js`](server/server.js) | the self-hosted backend — Node stdlib only, no dependencies |

## Tests

```sh
luajit tests/run.lua          # codecs, pairing codes, the decision table
luajit tests/sync.test.lua    # two devices over one cloud, including conflicts
node   tests/server.test.js   # the self-hosted backend, over real HTTP
```

Plus `tests/mod_load.test.lua`, which runs inside a Gen1Recomp checkout and
loads the mod through the engine's own mod SDK — real loader, real hooks,
real screen construction. See [tests/README.md](tests/README.md).

`tests/sync.test.lua` plays out the sequence that matters: A uploads, B
adopts, both edit while apart, sync refuses, the player answers, and the
losing save is still recoverable afterwards. Break the conflict rule and
eight of its checks fail.

## Licence

MIT. See [LICENSE](LICENSE).
