# Tests

Four suites. The first two need nothing but luajit; the load test needs a
gen1recomp checkout; the live end-to-end needs a gen1mmo-server checkout
and Node 24+.

```sh
luajit tests/run.lua            # codecs, sandbox rules, the safety table
luajit tests/sync.test.lua      # two devices over one slot server (fake, exact rules)
node   tests/live.e2e.test.js   # the SHIPPED stack vs the REAL server
```

The load test runs inside a Gen1Recomp checkout, through the engine's own
mod SDK and sandbox:

```sh
cp -r mod       /path/to/gen1recomp/mods/savesync
cp tests/mod_load.test.lua /path/to/gen1recomp/tests/savesync_load_test.lua
cd /path/to/gen1recomp
luajit tests/savesync_load_test.lua
```

## What each one is for

**`run.lua`** -- the pieces with exact right answers: base64/JSON codecs,
the platform-sandboxing scan (nothing reaches os.getenv/io.popen without a
guard), backup thinning, and above all **Sync.assess** -- the three-hash
table under the rule that the only silent flow is new local progress moving
up. Mutate the rule and it fails by name.

**`sync.test.lua`** -- two independent devices (own disk, own module
copies, own config) over one fake server that implements the REAL slot
rules (lineage binding, baseRev, confirm, tombstone expiry -- mirrored from
gen1mmo-server's src/sync/slots.ts, which has its own suite). Plays out the
stories: adopt, fast-forward, both-changed conflict answered both ways with
the loser recoverable, same-game and cross-game isolation, expiry and
revival, logout hygiene.

**`mod_load.test.lua`** -- the real loader, the real sandbox: manifest
(including the Gold claim), exports, menu rows, screen construction, config
round trip, gate wrapping.

**`live.e2e.test.js`** -- the crown: boots the real gen1mmo-server, then
drives the SHIPPED serverlink/net/tunnel stack over a real TCP socket --
X25519 handshake against the real pin, PoW registration, chunked
hostile-byte uploads, byte-identical cross-device download, both conflict
refusals, wrong password, wrong pin failing closed, name_taken. The crypto
in the harness's love-shim is FIPS-vector-checked at load, so the tunnel
cannot pass by accident.

Fixture rule, learned the hard way twice: **every payload carries hostile
bytes** (NULs, high bit, quotes). An ASCII-only fixture is how a
binary-unsafe path ships.
