# Tests

Four suites, none of which need a ROM, a GPU, or a network connection.

```sh
luajit tests/run.lua           # codecs, pairing codes, the decision table
luajit tests/sync.test.lua     # two devices over one shared cloud
node   tests/server.test.js    # the self-hosted backend, over real HTTP
```

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
