# The sync protocol

Small enough to reimplement in an afternoon, which is the point.

## The namespace

A provider stores a flat set of named blobs. For each save:

| name | contents |
| --- | --- |
| `<key>.sav` | the save file, byte-identical to what the game wrote |
| `<key>.json` | the manifest below |
| `<key>.h<seq>.sav` | a previous version, `seq` zero-padded to four digits |

`<key>` is `<version>-<playthroughId>` — for example `red-PLAY0001A2B3C4D5`.
The playthrough id is the engine's own (`save.meta.playthroughId`), which is
what makes cross-device pairing work: it travels *inside* the save, so the
same playthrough carries the same key onto a machine that has never seen it,
whatever save slot it lands in there.

A save with no playthrough id yet (a pre-identity save, before the next
in-game SAVE stamps one in) uses `<version>-<slotId>`, which is stable on the
device that holds it.

## The manifest

```json
{
  "v": 1,
  "key": "red-PLAY0001A2B3C4D5",
  "hash": "3f2a...",
  "seq": 4,
  "parent": "9c1b...",
  "device": "a3f19e22",
  "deviceName": "Windows PC",
  "savedAt": 1786000000,
  "uploadedAt": 1786000042,
  "player": "RED",
  "badges": 3,
  "time": "4:12",
  "dex": 41
}
```

* `hash` — content hash of `<key>.sav`. SHA-1 where LÖVE provides it. It is
  **opaque**: both sides only ever compare it for equality, so a provider or
  a reimplementation may use any stable digest as long as it is consistent
  with itself.
* `seq` — monotonic version counter. Increments on every upload; names the
  history entry.
* `parent` — the `hash` this upload was based on. Not used for decisions;
  it is there so a human reading the gist can reconstruct the order of
  events.
* `player` / `badges` / `time` / `dex` — display only, so the conflict screen
  can say *"cloud (Laptop): 5 badges, 6:40"* instead of showing two hashes.

## The decision

Three hashes: `local` (on disk), `cloud` (the manifest), `agreed` (the last
state this device and the cloud were known to share, kept locally and never
uploaded).

| local | cloud | verdict |
| --- | --- | --- |
| present | absent | upload |
| absent | present | download |
| equal | equal | in sync |
| moved from `agreed` | unchanged | upload |
| unchanged | moved from `agreed` | download |
| moved | moved | **conflict — stop and ask** |

`agreed = nil` (this device has never synced this save) with two differing
sides is a conflict, not a race to publish.

Timestamps are never used to pick a winner.

## An upload

One batch write:

```
<key>.sav        <- the new bytes
<key>.json       <- the new manifest, seq = cloud.seq + 1
<key>.h<seq>.sav <- the new bytes again, as a history entry
<key>.h<old>.sav <- deleted, for everything past the tenth newest
```

Because every upload archives itself, the version a device overwrites is
already in history — put there by whichever device wrote it. The loser of a
conflict is therefore always recoverable from either side.

## Local state

None of this is uploaded.

| path (in the LÖVE save directory) | contents |
| --- | --- |
| `savesync/config.lua` | provider, credentials, device id, per-key `syncedHash`/`syncedSeq` |
| `savesync/backups/<key>/<stamp>-<hash>-<tag>.sav` | the last ten displaced local saves |
| `savesync/tmp/` | staged request bodies, deleted immediately after use |

The config deliberately does **not** live in the game save. `mod.save:set`
would put the access token into `save.lua` — the very file this mod uploads —
which would publish the player's credentials to their own cloud and make the
token part of the synced state.

## Setup codes

`SSYNC1.` + URL-safe base64 (no padding) of a JSON object:

```json
{ "provider": "server", "url": "https://saves.example.com", "token": "..." }
```

It says *where the saves live*, never what they are. No save data is ever in
a setup code.

`Pairing.decode` also accepts the code wrapped as
`gen1recomp://savesync?c=<code>`, and tolerates surrounding whitespace and
line breaks, because that is what people actually paste.

## The self-hosted HTTP API

Four endpoints. Every request carries `Authorization: Bearer <token>`; the
token names one storage folder.

```http
GET  /v1/hello           -> 200 { "ok": true, "name": "My save server" }
GET  /v1/files           -> 200 { "files": { "red-PLAY0001.sav": 32768 } }
GET  /v1/file/<name>     -> 200 <raw bytes>  |  404
POST /v1/batch           -> 200 { "ok": true, "wrote": 3, "deleted": 1 }
     body: { "files": { "<name>": "<contents>" | null } }
```

`null` deletes. A batch is validated in full before any of it is written, so
one bad name cannot leave the store half-updated. Names must match
`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` — no slashes, no leading dot, no
traversal.

`GET /health` needs no token and answers `{ "ok": true }`.
