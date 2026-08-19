-- LIVE END-TO-END: the shipped client stack against the REAL server.
--
--   luajit tests/live.e2e_client.lua <host> <port> <pin>
--
-- Everything between "register an account" and "bytes on a second device"
-- is the shipping code, unmodified:
--
--   serverlink.lua -> net.lua -> tunnel.lua (X25519 + ChaCha20-Poly1305,
--   the pin VERIFIED) -> a real TCP socket -> gen1mmo-server -> sqlite
--
-- The only stand-ins are the platform seams a headless luajit lacks: a
-- love shim whose SHA-256 is checked against FIPS vectors at load, and a
-- luasocket-shaped FFI socket. If any byte of the crypto disagrees with
-- Node's, the HANDSHAKE fails -- this test cannot pass by accident.
--
-- Driven by tests/live.e2e.test.js, which boots the server and knows the
-- pin. PoW runs at the server's test difficulty.

local host, port, pin = ...
assert(host and port and pin, "usage: luajit tests/live.e2e_client.lua <host> <port> <pin>")

package.path = "./?.lua;./mod/?.lua;" .. package.path

require("tests.love_stub")
package.preload["socket"] = function() return require("tests.nb_socket") end

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end

local cache = {}
function SAVESYNC_INCLUDE(path)
  if cache[path] then return cache[path] end
  local chunk = assert(loadfile("mod/" .. path))
  cache[path] = chunk()
  return cache[path]
end

local Link = SAVESYNC_INCLUDE("src/serverlink.lua")

local function pump(link, until_, timeout)
  local deadline = os.clock() + (timeout or 20)
  while os.clock() < deadline do
    link:update()
    if until_(link) then return true end
  end
  return false
end

local NAME = "E2E" .. tostring(os.time() % 100000)

-- ------------------------------------------------------- registration

local events = {}
local link = Link.new({
  host = host, port = tonumber(port), pin = pin, version = "2.0.0-e2e",
  onEvent = function(kind, data) events[kind] = data end,
})

check("transport available", Link.transportAvailable())

link:register(NAME, "hunter2-e2e")
check("registration reaches ready over the REAL tunnel",
  pump(link, function(l) return l:ready() or l.state == "error" end, 60),
  link.status)
eq("and lands ready", link.state, "ready", link.status or link.errorCode)
eq("as the requested account", link.name, NAME)
check("a recovery code was issued once", type(link.recoveryCode) == "string"
  and #link.recoveryCode > 10, link.recoveryCode)
check("credentials event carried the derived verifier",
  type(events.credentials) == "table" and events.credentials.name == NAME
  and type(events.credentials.verifier) == "string")
local verifier = events.credentials and events.credentials.verifier
eq("the fresh account has empty slots", #(link.slots or { 1 }), 0)

-- ------------------------------------------------------- upload

-- hostile bytes, always: high bit, NUL, quotes, the exact classes that
-- broke v1 -- plus enough bulk to need many chunked parts
local save = "return { player = { id = 'e2e' }, blob = \""
  .. string.rep("\233\0\255\128'x\"y", 1200) .. "\" }"

local uploaded, upErr
link:upload(2, { game = "red", playthrough = "abcd1234", label = "RED E2E 3B" },
  save, 0, false, function(rev, err) uploaded, upErr = rev, err end)
check("the chunked upload lands", pump(link, function() return uploaded or upErr end, 30), upErr)
eq("at rev 1", uploaded, 1, upErr)

local listed
link:list(function(slots) listed = slots end)
pump(link, function() return listed end, 10)
check("the slot lists", listed and #listed == 1)
eq("with its label", listed and listed[1].label, "RED E2E 3B")
eq("and full expiry ahead", listed and listed[1].expiresIn, 30)

-- ------------------------------------------------------- second device

link:disconnect()

local link2 = Link.new({ host = host, port = tonumber(port), pin = pin,
  version = "2.0.0-e2e" })
link2:loginStored(NAME, verifier)
check("device two signs in with the stored verifier",
  pump(link2, function(l) return l:ready() or l.state == "error" end, 30),
  link2.status or link2.errorCode)
eq("ready", link2.state, "ready", link2.errorCode)

local got, gotMeta, gotErr
link2:download(2, function(bytes, err, meta) got, gotErr, gotMeta = bytes, err, meta end)
pump(link2, function() return got or gotErr end, 30)
check("the download completes", got ~= nil, gotErr)
check("BYTE-IDENTICAL across devices, hostile bytes included", got == save)
eq("with the lineage intact", gotMeta and gotMeta.game, "red")
eq("and the playthrough id", gotMeta and gotMeta.playthrough, "abcd1234")

-- ------------------------------------------------------- the refusals

-- a different adventure into the same slot: refused with the holder
local clashErr, clashHave
link2:upload(2, { game = "gold", playthrough = "ffff9999", label = "GOLD" },
  save, 0, false, function(_, err, have) clashErr, clashHave = err, have end)
pump(link2, function() return clashErr end, 20)
eq("gold onto red is refused by the REAL server", clashErr, "slot_conflict")
eq("naming what the slot holds", clashHave and clashHave.game, "red")

-- a stale baseRev: refused as a question
local staleErr
link2:upload(2, { game = "red", playthrough = "abcd1234", label = "RED old" },
  save, 0, false, function(_, err) staleErr = err end)
pump(link2, function() return staleErr end, 20)
eq("a stale device is refused, not obeyed", staleErr, "sync_conflict")

-- the player's confirm goes through
local confRev
link2:upload(2, { game = "gold", playthrough = "ffff9999", label = "GOLD OK" },
  "return { gold = true }", 0, true, function(rev) confRev = rev end)
pump(link2, function() return confRev end, 20)
check("confirm replaces through the same frames", confRev ~= nil)

-- ------------------------------------------------------- wrong password

link2:disconnect()
local link3 = Link.new({ host = host, port = tonumber(port), pin = pin,
  version = "2.0.0-e2e" })
link3:login(NAME, "not-the-password")
pump(link3, function(l) return l.state == "error" or l:ready() end, 30)
eq("a wrong password is refused", link3.state, "error")
eq("with the bad_proof code", link3.errorCode, "bad_proof")

-- ------------------------------------------------------- wrong pin

local link4 = Link.new({ host = host, port = tonumber(port),
  pin = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", version = "2.0.0-e2e" })
link4:login(NAME, "hunter2-e2e")
pump(link4, function(l) return l.state == "error" end, 20)
eq("a wrong pin fails CLOSED before any credential is sent",
  link4.errorCode, "bad_identity")

-- ------------------------------------------------------- name taken

local link5 = Link.new({ host = host, port = tonumber(port), pin = pin,
  version = "2.0.0-e2e" })
link5:register(NAME, "some-other-password")
pump(link5, function(l) return l.state == "error" or l:ready() end, 60)
eq("re-registering the name is refused", link5.errorCode, "name_taken",
  link5.state)
-- (the mod words this as: SaveSync and Gen1MMO share accounts -- log in)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
