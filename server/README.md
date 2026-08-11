# Self-hosted cloud saves

The fallback that means this mod outlives any one company. One file of Node,
no dependencies, no database — saves are small files in a folder.

You do **not** need this. GitHub and Dropbox are easier and free. Run this if
you would rather your saves lived on hardware you control, or if you want to
keep playing after every free service in the world has changed its mind.

## Run it

```sh
cd server
docker compose up -d
docker compose logs cloudsaves
```

The log prints a setup code:

```
Paste this into the game (Cloud Saves -> Set Up -> Use a setup code):

  G1CS1.eyJwcm92aWRlciI6InNlcnZlciIsInVybCI6Imh0dHA6...
```

Copy it, then in the game: **Cloud Saves → Set Up → Use a setup code →
Paste from clipboard**. Repeat on every device. That is all.

The code is also written to `/data/setup-code.txt` inside the container:

```sh
docker compose exec cloudsaves cat /data/setup-code.txt
```

### Set `PUBLIC_URL` first

The setup code has the server's address baked into it, so get it right
*before* you copy the code out. Edit `compose.yaml`:

```yaml
PUBLIC_URL: "http://192.168.1.10:8787"     # your machine's LAN address
```

On a LAN, that is the host's IP. Behind a reverse proxy or a tunnel, the
public `https://` URL. `localhost` only works if the game runs on the same
machine.

Changed it after the fact? Restart and re-read the code — the token is
unchanged, so re-pairing is quick.

## Configuration

| variable | default | meaning |
| --- | --- | --- |
| `PUBLIC_URL` | `http://localhost:8787` | the address baked into the setup code |
| `SERVER_NAME` | `My save server` | shown on the game's Cloud Saves screen |
| `PORT` | `8787` | listen port inside the container |
| `DATA_DIR` | `/data` | where saves live |
| `CLOUDSAVE_TOKENS` | *(minted on first boot)* | comma-separated; one per person who should have **separate** storage |

Leave `CLOUDSAVE_TOKENS` unset and the server mints one on first boot and
saves it to `/data/tokens.json`.

**A token is a password.** Anyone holding it can read and replace those
saves. Share it between your own devices; do not paste it in public.

### More than one person

Give each person their own token — separate tokens mean completely separate
storage:

```yaml
CLOUDSAVE_TOKENS: "alice-long-random-string,bob-different-long-string"
```

Everyone who should share saves uses the same token.

## Exposing it beyond your LAN

Plain HTTP is fine on a home network. Over the internet, put it behind
something that terminates TLS — a reverse proxy, Tailscale, or a tunnel — and
set `PUBLIC_URL` to the `https://` address. The bearer token travels in a
header, so without TLS anyone on the path can read it.

## Running it somewhere free

Checked August 2026, and honestly: the free-PaaS landscape for *persistent*
containers is thin. Fly.io ended its free tier in 2024, Koyeb closed its free
tier to new users after the Mistral acquisition (and never allowed volumes on
it), and Render's free tier has no persistent disk. A free container without
a disk will lose your saves on the next redeploy.

What actually works, in rough order of how little it costs you:

1. **A machine you already have.** A NAS, a home server, a spare Pi, an
   always-on desktop. This is the intended deployment.
2. **A free-tier VM** with a real disk (Oracle Cloud's always-free ARM
   instances are the usual answer) running Docker.
3. **A cheap VPS.** This service idles at a few megabytes of RAM; the
   smallest tier anyone sells is oversized for it.

If you do put it on a platform with an ephemeral filesystem, mount a real
volume at `/data` or accept that a redeploy is a wipe. The compose file uses
a named volume for exactly this reason.

## Backups

Saves are plain files:

```sh
docker compose exec cloudsaves tar -cf - -C /data stores | gzip > saves-backup.tar.gz
```

The game keeps its own local backups too, so this is a third line of defence,
not the only one.

## Protocol

Four endpoints, documented in [../docs/protocol.md](../docs/protocol.md).
Reimplementing this server in another language is a genuinely small job, and
the mod will not know the difference.

## Tests

```sh
node ../tests/server.test.js
```

Boots the real server against a throwaway directory and drives it over real
HTTP: auth, batch atomicity, path-traversal rejection, size ceilings, and the
setup code.
