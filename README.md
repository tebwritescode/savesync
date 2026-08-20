# SaveSync

> **Gen1Recomp now syncs your saves for you.** As of the v0.2.10 client there
> is a built-in **Sync** tab in the launcher that carries your saves (and mods)
> across your devices natively — no account setup, no mod required. **Use that.**
>
> SaveSync came before the official feature. It still works against the
> Gen1MMO server, but the built-in sync is the simpler path for everyone now,
> so that's where to start. The rest of this page is kept for anyone still
> running the mod.

---


**Automatic cross-device saves for
[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) — five free cloud
slots on the official server, and your save follows you to every device you
play on.**

Play on the desktop, close it, open the game on the phone, press CONTINUE.
Your save is there. One account looks after it — the same account that plays
Gen1MMO.

## One account, two mods

A SaveSync account **is** a Gen1MMO account. Register in either, log into
both. No email, no personal details: a name, a password, and a one-time
recovery code shown once at registration.

> Write the recovery code down. If you lose your password AND the code, the
> account is gone — nobody can restore it. That is what keeps it yours.

## Five slots, your call

Every account has five cloud slots. Each holds one save — any game, any
playthrough — and the slots screen shows what lives where: game, trainer,
badges, and how many days remain before it expires.

**Saves expire after 30 days untouched.** The server keeps its space for
active players; an expired slot says EXPIRED right where the save was, your
account stays, and uploading again brings the slot back. Playing normally
refreshes the clock every time you sync.

## Your progress is protected

This is the part that matters most, so it is the part with the most care in
it. **Nothing replaces a save without asking you.**

- **New progress uploads by itself** after you save. That is the only silent
  flow in the whole mod.
- **A slot holding a different adventure refuses your upload** until you
  confirm — Red cannot land on Gold, and your second playthrough cannot land
  on your first, by accident.
- **A slot another device moved shows both sides and asks** — *"here: 3
  badges"* against *"server: 5 badges"* — so the choice is always yours.
  The server enforces the same rule on its own, so even a modified client
  cannot overwrite your progress unasked.
- **Downloads always confirm**, and every replacement backs up the outgoing
  save first — ten past versions per save live on the device.
- **CONTINUE speaks up** when the server holds a newer save for the game you
  are about to load, and offers it. Offline is a normal way to play.

## Private on the wire

Every connection runs inside an encrypted tunnel (X25519 key agreement,
ChaCha20-Poly1305 framing) with the server's identity pinned in this public
source — a connection that cannot prove that key is refused. Your password
never leaves the device: a derived verifier travels once, inside the tunnel,
and the server hardens it again before it touches disk.

Because the tunnel is the mod's own, SaveSync runs on **every device the
game runs on** — Windows, macOS, Linux, Android, iOS — with the same code.

## Snapshots, and why they are on

Every five minutes SaveSync quietly takes a **snapshot** — a copy of where
you are, kept beside your save. A crash costs you minutes instead of an
evening, and your save file stays exactly as you left it, so soft-resetting
to re-roll a starter or a legendary works the way it always has.

There is also a plain auto-save that writes a real save file on a timer.
That one ships off and is yours to switch on — and it can target a **slot of
your choosing**, so the timer's copy lives in its own slot and the save you
manage by hand stays exactly yours.

## Install

1. Have Gen1Recomp 0.2.0+ set up with your own legally-obtained ROM.
2. Download the latest `savesync-<version>.zip` from Releases.
3. Launcher → MODS → **Import mod .zip**, then enable **SaveSync**.
4. Title screen → **SAVESYNC** → Set up account → Register (or **Log in**
   with your Gen1MMO account).

On your other devices, repeat step 4 and log in. Your slots are waiting.

It asks for `network` to reach the server, `filesystem` for its own backups,
and `engine_internals` to read and replace save slots through the engine's
own code — so the rules about where your progress lives stay in one place.

## Status

| | |
|---|---|
| Five cloud slots on the official server | ✅ |
| One account shared with Gen1MMO | ✅ |
| Red, Blue, Yellow and Gold | ✅ |
| Every replace is a question, both sides shown | ✅ |
| 30-day expiry with in-game countdown, expired slots visible | ✅ |
| Encrypted tunnel, pinned server identity | ✅ |
| Ten local backups per save | ✅ |
| Snapshots every 5 min, restorable, save file left alone | ✅ |
| Autosave with a slot picker | ✅ |
| Works offline and retries later | ✅ |

## Running your own server

The server is [gen1mmo-server](https://github.com/tebwritescode) — one Node
process, zero dependencies, SQLite on disk. Run it, note the identity pin it
prints, and point the mod at it via `savesync/config.lua` (`serverHost`,
`serverPort`, `serverPin`). Everything the official server does, yours does.

## For developers

The slot protocol and its refusal rules live in the server's
`src/sync/slots.ts` and this mod's `src/serverlink.lua` — small enough to
read in one sitting, which is deliberate. Tests live in
[tests/](tests/README.md), including a live end-to-end that drives the
shipped tunnel against a real server instance.

## Licence

MIT. Original code and original artwork throughout; the mod ships and
uploads save data alone.
