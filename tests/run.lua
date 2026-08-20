-- Pure-Lua tests for the parts of the mod that can be tested without LÖVE:
-- the codecs, the platform-sandboxing rules, the backup thinning, and --
-- most importantly -- Sync.assess, the three-hash table that keeps any
-- replace from ever being silent.
--
--   luajit tests/run.lua
--
-- No LÖVE, so the fallback code paths in util.lua (pure-Lua base64, the
-- rolling hash) are what actually gets exercised.  That is deliberate: those
-- are the paths nothing else covers.

package.path = "./mod/?.lua;" .. package.path

local ROOT = "mod/"
local cache = {}
function SAVESYNC_INCLUDE(path)
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
  listSlots = function() return {} end,
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

local Json = SAVESYNC_INCLUDE("src/json.lua")

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

local Util = SAVESYNC_INCLUDE("src/util.lua")

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

-- ------------------------------------------------- platform sandboxing

-- A REAL iOS CRASH LIVES HERE.
--
-- `os.getenv` is absent on the iOS build, so an unguarded call in main.lua
-- threw while the mod was loading and every iOS player saw
-- "attempt to call field 'getenv' (a nil value)" in the mod manager instead
-- of the mod. It cost nothing on desktop and everything on a phone.
--
-- The engine itself calls os.getenv freely, so this cannot be tested by
-- removing the function -- the harness needs it. Assert the rule at the
-- source instead: anything the mod reaches on a phone goes through a guard.
local SANDBOXED = { "os%.getenv", "os%.execute", "io%.popen", "os%.tmpname" }
local MOD_FILES = {
  "main.lua", "src/sync.lua", "src/store.lua", "src/ui.lua", "src/gate.lua",
  "src/snapshot.lua", "src/autosave.lua", "src/util.lua", "src/json.lua",
  "src/serverlink.lua", "src/net.lua", "src/tunnel.lua", "src/crypto.lua",
  "src/authshare.lua",
}
for _, file in ipairs(MOD_FILES) do
  local fh = io.open(ROOT .. file, "rb")
  check("readable: " .. file, fh ~= nil)
  if fh then
    local src = fh:read("*a")
    fh:close()
    -- Strip the guard itself before searching, so the one place that DOES
    -- name os.getenv -- to test for it before calling -- is not a false hit.
    local cleaned = src
      -- Comments first: the guard's own explanation names os.getenv, and a
      -- scanner cannot tell prose from a call site.
      :gsub("%-%-[^\r\n]*", "")
      :gsub('type%(os%.getenv%) ~= "function"', "")
      :gsub("pcall%(os%.getenv, name%)", "")
    for _, pattern in ipairs(SANDBOXED) do
      check(("%s has no unguarded %s"):format(file, (pattern:gsub("%%", ""))),
        cleaned:find(pattern) == nil,
        "absent on iOS -- guard it or the mod fails to load there")
    end
  end
end

-- v2 makes NO environment reads at all: the OAuth override the guard was
-- built for died with the providers. The scan above still fails the build
-- if an unguarded one ever returns.


-- ---------------------------------------------------------- thinning

-- The complaint that produced this: "a list of 40 saves for 10 minutes play
-- is like insane". A flat cap cannot fix that -- it just picks WHICH forty.
do
  -- Twelve writes inside one hour, then a few spread over previous days.
  local names = {}
  for i = 1, 12 do
    names[#names + 1] = ("20260812-14%02d00-abcd1234.sav"):format(i)
  end
  names[#names + 1] = "20260812-130000-aaaa1111.sav"   -- an hour earlier
  names[#names + 1] = "20260812-120000-bbbb2222.sav"   -- two hours earlier
  names[#names + 1] = "20260811-140000-cccc3333.sav"   -- yesterday
  names[#names + 1] = "20260810-140000-dddd4444.sav"   -- the day before

  local keep = Util.thin(names)
  local kept = 0
  for _ in pairs(keep) do kept = kept + 1 end
  check("thinning collapses a burst", kept < #names,
    ("kept %d of %d"):format(kept, #names))

  -- The most recent must always survive -- it is what people want back.
  check("the newest is always kept", keep["20260812-141200-abcd1234.sav"] == true)

  -- And so must the older days, which a flat "newest ten" would have evicted
  -- in favour of ten copies of the same afternoon.
  check("yesterday survives a busy today", keep["20260811-140000-cccc3333.sav"] == true)
  check("the day before survives too", keep["20260810-140000-dddd4444.sav"] == true)

  -- One per hour, not twelve.
  local sameHour = 0
  for name in pairs(keep) do
    if name:sub(1, 11) == "20260812-14" then sameHour = sameHour + 1 end
  end
  -- At most KEEP_LAST recent ones, plus the hour's own slot, plus the day's
  -- slot (which today's newest remaining candidate fills). Six of twelve,
  -- not twelve.
  check("one busy hour does not fill the list", sameHour <= Util.KEEP_LAST + 2,
    "kept " .. sameHour .. " from a single hour")

  -- Names from an older build carry no stamp; dropping them would silently
  -- lose a restore point somebody already has.
  local legacy = Util.thin({ "oldstyle.sav", "20260812-141200-abcd1234.sav" })
  check("an unstamped legacy name is kept", legacy["oldstyle.sav"] == true)

  eq("empty input is fine", next(Util.thin({})), nil)
end

-- ----------------------------------------------------- the safety table
--
-- Sync.assess is v2's decision function, and it encodes the owner's rule
-- verbatim: the ONLY silent flow is new local progress moving up. A server
-- that moved -- with or without local changes -- is a QUESTION. Guessing by
-- timestamp is exactly how naive sync eats a playthrough, so no timestamp
-- appears anywhere in the signature.

local Sync = SAVESYNC_INCLUDE("src/sync.lua")
local A = Sync.assess

eq("assess: all agree",                 A("a", "a", "a"), "match")
eq("assess: agree, stale record",       A("a", "a", "z"), "match")
eq("assess: agree, no record",          A("a", "a", nil), "match")
eq("assess: local moved only",          A("b", "a", "a"), "upload")
eq("assess: server moved only -> ASK",  A("a", "b", "a"), "ask_download")
eq("assess: both moved -> ASK",         A("b", "c", "a"), "ask_both")
eq("assess: no record, differ -> ASK",  A("b", "c", nil), "ask_both")

-- A fresh device (no local copy) adopting a server save is a download and
-- downloads always ask; the UI reaches that flow explicitly, so assess only
-- ever compares real hashes. nil local means "not this function's case".


-- ----------------------------------------------------- shared login (authshare)
--
-- Two mods in one Lua state: one is signed in, the other has no account and
-- must ADOPT the first's credential through the exports channel, not prompt.

local AuthShare = SAVESYNC_INCLUDE("src/authshare.lua")

-- a fake mod that publishes a credential and can find a sibling
local function fakeMod(id, cred, siblings)
  local m = { id = id, exports = {} }
  m.find = function(a, b)
    local otherId = (b == nil) and a or b
    local sib = siblings[otherId]
    if not sib then return nil end
    return { id = otherId, version = "1", exports = sib.exports }
  end
  AuthShare.publish(m, function() return cred end)
  return m
end

local world = {}
local gen1 = fakeMod("gen1mmo",
  { name = "Ash", verifier = "VER", deviceSeed = "aa", deviceEnrolled = true }, world)
local saves = fakeMod("savesync", nil, world)
world.gen1mmo, world.savesync = gen1, saves

local adopted, fromId = AuthShare.adopt(saves, "savesync")
check("authshare: a signed-out mod adopts a sibling's credential",
  type(adopted) == "table" and adopted.name == "Ash")
eq("authshare: it carries the verifier, never a password", adopted and adopted.verifier, "VER")
eq("authshare: and the device key travels too", adopted and adopted.deviceSeed, "aa")
eq("authshare: naming the sibling it came from", fromId, "gen1mmo")

-- a mod never adopts from ITSELF (selfId excluded)
local onlyMe = AuthShare.adopt(gen1, "gen1mmo")
check("authshare: a mod does not adopt its own export", onlyMe == nil)

-- signed-out siblings offer nothing
local emptyWorld = {}
local a2 = fakeMod("savesync", nil, emptyWorld)
local b2 = fakeMod("gen1mmo", nil, emptyWorld)
emptyWorld.savesync, emptyWorld.gen1mmo = a2, b2
check("authshare: nothing to adopt when no sibling is signed in",
  AuthShare.adopt(a2, "savesync") == nil)

-- ------------------------------------------------------------- report

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
