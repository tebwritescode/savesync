-- Pure-Lua tests for the parts of the mod that can be tested without LÖVE:
-- the codecs, the pairing-code round trip, and -- most importantly -- the
-- sync decision table, which is the one function here that can lose a
-- playthrough if it is wrong.
--
--   luajit tests/run.lua
--
-- No LÖVE, so the fallback code paths in util.lua (pure-Lua base64, the
-- rolling hash) are what actually gets exercised.  That is deliberate: those
-- are the paths nothing else covers.

package.path = "./mod/?.lua;" .. package.path

local ROOT = "mod/"
local cache = {}
function CLOUD_SAVES_INCLUDE(path)
  if cache[path] then return cache[path] end
  local chunk = assert(loadfile(ROOT .. path))
  local v = chunk()
  cache[path] = v
  return v
end

-- The sync engine pulls in the store, which requires engine modules; stub
-- the two functions the tests below reach so the decision table can be
-- exercised on its own.
package.loaded["src.core.SaveData"] = {
  saveFilename = function() return nil end,
  activeSlot = function() return nil end,
  createSlot = function() return nil end,
  setActiveSlot = function() end,
  writeSlot = function() return true end,
  slotSummary = function() return nil, {} end,
}
package.loaded["src.core.SaveSerializer"] = {
  encode = function(t) return "return " .. tostring(t) end,
  decode = function() return nil end,
}
package.loaded["src.core.GameVersion"] = {
  info = function(id) return id == "red" or id == "blue" or id == "yellow" end,
  get = function() return "red" end,
}

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end

-- --------------------------------------------------------------- json

local Json = CLOUD_SAVES_INCLUDE("src/json.lua")

eq("json: object", Json.encode({ b = 1, a = "x" }), '{"a":"x","b":1}')
eq("json: empty table is an object", Json.encode({}), "{}")
eq("json: array", Json.encode({ 1, 2, 3 }), "[1,2,3]")
eq("json: escapes", Json.encode({ s = 'a"b\nc' }), '{"s":"a\\"b\\nc"}')

local round = Json.decode('{"a":[1,2,{"b":true}],"c":null,"d":"x\\ny"}')
eq("json: nested number", round.a[2], 2)
eq("json: nested bool", round.a[3].b, true)
eq("json: null is absent", round.c, nil)
eq("json: unescape", round.d, "x\ny")
check("json: garbage is nil", Json.decode("{not json") == nil)
check("json: empty is nil", Json.decode("") == nil)

-- --------------------------------------------------------------- util

local Util = CLOUD_SAVES_INCLUDE("src/util.lua")

eq("base64: known vector", Util.b64("Man"), "TWFu")
eq("base64: one pad", Util.b64("Ma"), "TWE=")
eq("base64: two pads", Util.b64("M"), "TQ==")
eq("base64: round trip", Util.unb64(Util.b64("hello world")), "hello world")

local binary = ""
for i = 0, 255 do binary = binary .. string.char(i) end
eq("base64: binary round trip", Util.unb64(Util.b64(binary)), binary)
eq("base64url: round trip", Util.unb64url(Util.b64url(binary)), binary)
check("base64url: no padding", not Util.b64url(binary):find("=", 1, true))
check("base64url: url safe", not Util.b64url(binary):find("[+/]"))

check("hash: stable", Util.hash("abc") == Util.hash("abc"))
check("hash: differs", Util.hash("abc") ~= Util.hash("abd"))
check("hash: length-sensitive", Util.hash("ab") ~= Util.hash("ab\0"))

eq("form: sorted and escaped", Util.form({ b = "2", a = "x y" }), "a=x%20y&b=2")
eq("ago: never", Util.ago(nil), "never")
eq("ago: just now", Util.ago(os.time()), "just now")
eq("ago: hours", Util.ago(os.time() - 7200), "2 hours ago")

-- ------------------------------------------------------------ pairing

local Pairing = CLOUD_SAVES_INCLUDE("src/pairing.lua")

local code = Pairing.encode("server",
  { url = "https://saves.example.com", token = "sekrit", account = "Home" })
check("pairing: has prefix", code:sub(1, 6) == "G1CS1.")
local decoded = assert(Pairing.decode(code))
eq("pairing: provider", decoded.provider, "server")
eq("pairing: url", decoded.url, "https://saves.example.com")
eq("pairing: token", decoded.token, "sekrit")

check("pairing: survives whitespace", Pairing.decode(" " .. code .. "\n ") ~= nil)
check("pairing: survives a uri wrapper",
  Pairing.decode("gen1recomp://cloudsaves?c=" .. code) ~= nil)
check("pairing: rejects junk", Pairing.decode("hello") == nil)
check("pairing: rejects a damaged code", Pairing.decode("G1CS1.!!!!") == nil)

-- A setup code must never be able to carry save data: it is built only from
-- what the provider chooses to export.
check("pairing: no save data in the code", not code:find("sav", 1, true))

local lines = Pairing.wrap(code, 19)
check("pairing: wraps", #lines >= 1 and #lines[1] <= 19)
eq("pairing: wrap is lossless", table.concat(lines), code)

-- --------------------------------------------------- the decision table

local Sync = CLOUD_SAVES_INCLUDE("src/sync.lua")
local D = Sync.decide

eq("decide: first upload",            D("a", nil, nil), "upload")
eq("decide: new device adopts",       D(nil, "a", nil), "download")
eq("decide: nothing anywhere",        D(nil, nil, nil), "nothing")
eq("decide: identical",               D("a", "a", "a"), "insync")
eq("decide: identical, never synced", D("a", "a", nil), "insync")
eq("decide: local moved",             D("b", "a", "a"), "upload")
eq("decide: cloud moved",             D("a", "b", "a"), "download")
eq("decide: both moved",              D("b", "c", "a"), "conflict")

-- The case that matters most: a device that has never synced this save, and
-- both sides hold different bytes.  There is no safe automatic answer, and
-- guessing by timestamp is exactly how naive sync eats a playthrough.
eq("decide: unknown history is a conflict", D("b", "c", nil), "conflict")

-- A device that is behind must not be talked into uploading by a stale
-- agreement record.
eq("decide: stale agreement, local unchanged", D("a", "b", "a"), "download")

-- ------------------------------------------------------------- report

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
