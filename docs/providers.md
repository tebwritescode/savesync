# Providers

A provider is "somewhere a handful of small named files can live". The sync
engine knows nothing else about it, which is the whole point: when a free
service changes its terms or disappears, the replacement is one file.

## The interface

Four functions, in `mod/src/providers/<id>.lua`:

```lua
P.link(state, opts)   -> Op -> cfg          -- sign in, or adopt a setup code
P.read(cfg, names)    -> Op -> { [name] = contents }   -- missing = absent
P.write(cfg, files)   -> Op -> true         -- files[name] = contents | false to delete
P.list(cfg)           -> Op -> { [name] = size }
```

plus `P.describe(cfg)` for the status line and `P.exportable(cfg)` for what a
pairing code may carry (return `nil` for "this provider has nothing safe to
hand over — sign in again instead").

An `Op` is a coroutine that can `ctx:http{...}`, `ctx:sleep(n)`,
`ctx:await(otherOp)` and `ctx:fail("message the player will read")`. Straight
line code, no frame ever blocked. See `mod/src/op.lua`.

Names are flat — `red-PLAY0001.sav`, `red-PLAY0001.json`,
`red-PLAY0001.h0004.sav`. No slashes, deliberately, so a provider whose
namespace is flat (a gist) needs no path mangling.

**`write` is a batch on purpose.** One sync writes the save, its manifest, a
history entry and a prune together. A provider that can do that in one
request leaves the store in either the old state or the new one, never half
of each.

### Adding one

1. Write `mod/src/providers/<id>.lua`.
2. Add it to the `LIST` in `mod/src/providers/init.lua`.
3. If it needs a client id, add an entry to `mod/providers.json`.

Nothing else in the mod changes. `mod/src/providers/gdrive.lua` is a
deliberately unfinished example with the shape filled in.

---

## Registering the OAuth apps

These client ids are **public values**. The GitHub device flow and Dropbox
PKCE exist so that a desktop app needs no client secret — there is nothing to
leak. They are per-distribution, so register your own rather than borrowing
someone else's; a shared id means a shared rate limit and a consent screen
with the wrong name on it.

### GitHub — about two minutes

1. <https://github.com/settings/developers> → **OAuth Apps** → **New OAuth App**
2. Application name: whatever the player should see on the consent screen
   (e.g. `Gen1Recomp Cloud Saves`).
3. Homepage URL: your project page. Authorization callback URL: anything —
   the device flow never uses it, but the form requires a value.
4. Register, then on the app's page tick **Enable Device Flow**. *(Without
   this the sign-in fails at the very first request.)*
5. Copy the **Client ID** into `mod/providers.json` under `github.client_id`.

There is no client secret to copy and no verification to wait for.

The mod requests the `gist` scope and nothing else — it can create and read
gists, and cannot see repositories, code, or anything else in the account.
Saves live in one **secret** gist described exactly
`gen1recomp cloud saves (do not rename)`, which is how a second device finds
the same storage after signing in.

### Dropbox — about two minutes

1. <https://www.dropbox.com/developers/apps> → **Create app**
2. Choose **Scoped access**, then **App folder** (*not* Full Dropbox). The
   mod will only ever see `Apps/<your app name>/`.
3. Name it, create it, then on the **Permissions** tab enable
   `files.content.write` and `files.content.read`, and **Submit**.
4. Copy the **App key** into `mod/providers.json` under `dropbox.client_id`.

No app secret is needed — the flow is PKCE.

**One limit worth knowing before you ship:** a Dropbox app in development
status is capped at a small number of linked accounts (50 at the time of
writing). Past that you have to apply for production status. GitHub has no
equivalent cap, which is part of why it is the recommended default.

### Testing without editing a tracked file

```sh
export GEN1RECOMP_CLOUD_GITHUB_CLIENT_ID=Iv1.xxxxxxxxxxxx
export GEN1RECOMP_CLOUD_DROPBOX_APP_KEY=xxxxxxxxxxxxxxx
```

Both override `providers.json` at load.

---

## Why not the obvious alternatives

Recorded so the next person does not re-derive it.

* **A backend the mod author hosts.** Ruled out by the brief, and rightly:
  it makes one person responsible for everybody's saves, forever, for free.
* **A private GitHub repository instead of a gist.** Would need the `repo`
  scope, which grants read/write over *every* private repository the player
  owns. An absurd thing to ask in exchange for storing 32 KB.
* **Google Drive.** The `drive.appdata` scope is *sensitive*, so the OAuth
  client needs brand and security verification before more than a hundred
  users can consent, and Google's device flow does not offer Drive scopes at
  all — a loopback-redirect flow with a local listener is required. Shipping
  it half-working would be worse than not shipping it: players would pick the
  name they recognise and hit an "unverified app" warning.
* **A free PaaS with a persistent disk, deployed per user.** Checked in
  August 2026, and the picture is poor: Fly.io's free tier ended in 2024,
  Koyeb closed its free Starter tier to new users after the 2026 Mistral
  acquisition and never allowed volumes on it anyway, and Render's free tier
  has no persistent disk (disks are a paid add-on). Even where a free
  container exists, "sign up, create a service, wire a volume, set an env
  var" is not one click for a twelve-year-old. The self-hosted backend is
  therefore offered as the advanced option it actually is, rather than
  dressed up as the easy path.
