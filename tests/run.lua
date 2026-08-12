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

-- ------------------------------------------------------------ pairing

local Pairing = SAVESYNC_INCLUDE("src/pairing.lua")

local code = Pairing.encode("server",
  { url = "https://saves.example.com", token = "sekrit", account = "Home" })
check("pairing: has prefix", code:sub(1, 7) == "SSYNC1.")
local decoded = assert(Pairing.decode(code))
eq("pairing: provider", decoded.provider, "server")
eq("pairing: url", decoded.url, "https://saves.example.com")
eq("pairing: token", decoded.token, "sekrit")

check("pairing: survives whitespace", Pairing.decode(" " .. code .. "\n ") ~= nil)
check("pairing: survives a uri wrapper",
  Pairing.decode("gen1recomp://savesync?c=" .. code) ~= nil)
check("pairing: rejects junk", Pairing.decode("hello") == nil)
check("pairing: rejects a damaged code", Pairing.decode("SSYNC1.!!!!") == nil)

-- A setup code must never be able to carry save data: it is built only from
-- what the provider chooses to export.
check("pairing: no save data in the code", not code:find("sav", 1, true))

local lines = Pairing.wrap(code, 19)
check("pairing: wraps", #lines >= 1 and #lines[1] <= 19)
eq("pairing: wrap is lossless", table.concat(lines), code)

-- ---------------------------------------------------------- providers

-- providers.json is hand-edited whenever a distribution registers its OAuth
-- apps, and a stray comma there would break sign-in for everyone with no
-- other symptom, so it is parsed here rather than trusted.
local rawProviders = assert(io.open("mod/providers.json", "rb")):read("*a")
local providersCfg = Json.decode(rawProviders)
check("providers.json parses", type(providersCfg) == "table")
if type(providersCfg) == "table" then
  for _, id in ipairs({ "github", "dropbox" }) do
    local entry = providersCfg[id]
    check("providers.json has a " .. id .. " entry", type(entry) == "table")
    check(id .. " client id is a non-empty string",
      type(entry) == "table" and type(entry.client_id) == "string"
        and entry.client_id ~= "",
      "set it -- see docs/providers.md")
  end
end

local Dropbox = SAVESYNC_INCLUDE("src/providers/dropbox.lua")
local authUrl = Dropbox.authUrl("APPKEY", "CHALLENGE", "S256")

check("dropbox: authorize url points at Dropbox",
  authUrl:find("^https://www%.dropbox%.com/oauth2/authorize%?") ~= nil)
check("dropbox: carries the app key", authUrl:find("client_id=APPKEY", 1, true) ~= nil)
check("dropbox: asks for a code", authUrl:find("response_type=code", 1, true) ~= nil)
check("dropbox: carries the PKCE challenge",
  authUrl:find("code_challenge=CHALLENGE", 1, true) ~= nil
    and authUrl:find("code_challenge_method=S256", 1, true) ~= nil)
-- offline is what yields a refresh token; without it the link dies after
-- four hours and every device has to be paired again
check("dropbox: asks for offline access",
  authUrl:find("token_access_type=offline", 1, true) ~= nil)
-- Deliberate: the app's Permissions tab is both the default and the maximum,
-- so naming scopes here could only ever over-request and fail.
check("dropbox: sends no scope parameter",
  authUrl:find("scope=", 1, true) == nil)


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
  "src/snapshot.lua", "src/autosave.lua", "src/util.lua", "src/pairing.lua",
  "src/op.lua", "src/json.lua",
  "src/providers/init.lua", "src/providers/github.lua",
  "src/providers/dropbox.lua", "src/providers/server.lua",
  "src/providers/gdrive.lua",
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

-- And the one environment read the mod does make must be behind that guard.
local mainSrc = assert(io.open(ROOT .. "main.lua", "rb")):read("*a")
check("main.lua guards its environment read",
  mainSrc:find('type%(os%.getenv%) ~= "function"') ~= nil)


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

-- --------------------------------------------------- the decision table

local Sync = SAVESYNC_INCLUDE("src/sync.lua")
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
