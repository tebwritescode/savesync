# Tests

Six suites, none of which need a ROM, a GPU, or an internet connection.

```sh
luajit tests/run.lua           # codecs, pairing codes, the decision table
luajit tests/sync.test.lua     # two devices over one shared cloud
node   tests/server.test.js    # the self-hosted backend, over real HTTP
node   tests/e2e.test.js       # the whole stack: sync -> curl -> server
node   tests/github.test.js    # the GitHub provider, over real HTTP
node   tests/android.e2e.test.js  # the Android transport: vendored luasocket
```

`e2e.test.js` and `github.test.js` need `luajit` and `curl` on PATH.

The fourth runs inside a Gen1Recomp checkout, because it loads the mod
through the engine's own mod SDK:

```sh
cp -r mod       /path/to/gen1recomp/mods/savesync
cp tests/mod_load.test.lua /path/to/gen1recomp/tests/savesync_load_test.lua
cd /path/to/gen1recomp
luajit tests/savesync_load_test.lua
```

## What each one is for

**`run.lua`** — the pieces with exact right answers. Base64 against the RFC
vectors, a full 0–255 byte round trip, JSON edge cases (an empty table must
encode as `{}`, not `[]`, or the GitHub API rejects the request), pairing
codes surviving the whitespace and URL wrappers people actually paste, and
`Sync.decide` across every combination of the three hashes.

**`sync.test.lua`** — the scenario the whole mod exists to get right. Two
devices with separate in-memory disks over one shared cloud: A uploads, B
adopts, A updates, B follows, then **both edit while apart**. The test
asserts that sync refuses, that neither save is touched, that it keeps
refusing rather than drifting into a decision, and that after the player
answers, the losing save is still recoverable from cloud history and from
local backups.

To confirm it has teeth: change `Sync.decide` so a conflict returns
`"download"` and eight checks fail, led by *"B kept its own save untouched --
got 3, want 5"*. That is a silently lost playthrough, caught.

**`server.test.js`** — boots the real backend against a throwaway directory
and drives it over HTTP: auth rejection, batch write/update/delete, listing,
path-traversal and bad-name rejection, whole-batch atomicity (a bad name
anywhere writes nothing), the size ceiling, malformed JSON, and the setup
code the operator is told to paste.

**`mod_load.test.lua`** — the real engine loader, not a stub. Proves the
manifest, permissions and every module load clean, the two menu rows appear
through the real hooks, the screen registers *and constructs*, its update
loop runs, and the mod is completely inert until it is configured.

**`e2e.test.js`** — the whole stack with nothing stubbed between the sync
engine and the socket:

```
sync.lua -> providers/server.lua -> op.lua -> http.lua's WORKER SOURCE
         -> HostShell.popen -> curl -> server/server.js -> files on disk
```

The worker is not reimplemented for the test — its source is lifted verbatim
out of `mod/src/http.lua` and run against fake `love.thread` channels, so the
bytes on the wire are the bytes the game sends. It replays the same two-device
conflict story against a real server, then asserts from the *server's* API
that only save-shaped files arrived (the "never upload ROMs" guarantee,
checked against reality rather than intent).

It also asserts that a JSON value in a header survives the transport. That is
the `Dropbox-API-Arg` case, and it is not hypothetical: `HostShell.quote`
**deletes** double quotes on Windows rather than escaping them, so every
Dropbox call would have gone out malformed. Swap the config-file escaping for
that behaviour and the test reports exactly what Dropbox would have received:

```
got {path:/red-E2E00001.sav,mode:overwrite,mute:true}
want {"path":"/red-E2E00001.sav","mode":"overwrite","mute":true}
```

**`github.test.js`** — exists because a real player signed in with GitHub, a
gist was created holding only the link-time README, and no save ever
arrived, and `mod/src/providers/github.lua` had zero coverage past "did
`link()` return a cfg" to have caught it. GitHub has no sandbox to point a
real integration test at, so this stands one up: a fake gist API and OAuth
device flow, Node stdlib only, driven from `tests/github_client.lua` through
the real HTTP worker and real curl, same trick as `e2e_client.lua`. `cfg`
grows a same-shaped `apiBase`/`webBase` pair the provider reads if present
and ignores otherwise — nil for a real sign-in, so it costs a real player
nothing.

It found the bug for real. `apiHeaders()` never set `Content-Type`, so curl
labelled every `POST /gists` and `PATCH /gists/{id}` —
`Json.encode()`'d text, every time — as `application/x-www-form-urlencoded`
by default. Confirmed empirically by reverting the header and re-running:

```
FAIL: POST /gists Content-Type (/gists)  -- got "application/x-www-form-urlencoded", want "application/json"
FAIL: PATCH /gists/fakegist1 Content-Type  -- got "application/x-www-form-urlencoded", want "application/json"
```

Fixed by adding `Content-Type: application/json` to `apiHeaders()`. The gist
fixtures are deliberately realistic — a numeric `owner.id`, a nested `files`
map, a `history` array, several JSON `null`s — because `mod/src/json.lua` is
a hand-written decoder and a hand-trimmed fixture only ever proves the
decoder can read a hand-trimmed fixture. Beyond the header, the suite
asserts a full write actually lands the save and its manifest next to the
README (not just the README, which is the exact shape of the original bug),
that a mixed write can update one file and delete another in the same PATCH,
that an all-deletions write — the one code path that has to splice every
`null` in by string surgery because `Json.encode` has no way to emit a bare
`null` — still produces valid JSON, that a missing file reads back absent
rather than erroring, and that a second device's sign-in finds the first
device's gist by its description marker instead of creating a second one.

## Cross-platform

`HostShell.quote` has two branches — Windows double-quotes, POSIX
single-quotes — and **each host can only test its own**, because the command
still goes out through `io.popen` to the host's shell. Simulating the POSIX
branch on Windows only proves that `cmd.exe` dislikes single quotes, so the
suite runs the branch that matches the host and says which one it covered.

Verified on:

| platform | how |
| --- | --- |
| Windows 11 | LuaJIT 2.1 + curl 8.19, run directly |
| Linux x86_64 | LuaJIT 2.1 + curl 7.88 in `node:22-bookworm-slim` |
| macOS | **not yet run** — same POSIX branch as Linux, and macOS ships curl, but it is untested |
