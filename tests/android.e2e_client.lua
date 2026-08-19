-- ANDROID END-TO-END: the real worker, the REAL vendored luasocket, a real
-- server -- with the exact transport surface the Android APK has.
--
-- The Android build of the game ships NO lua-https and NO curl
-- (mobile/android/love/src/jni: luasocket is in libraries/, luahttps is
-- absent, and HostShell documents the missing curl as #597). Its only
-- plain-HTTP transport is luasocket, and its only TLS story is none. This
-- test therefore proves the one provider Android can use -- the self-hosted
-- server -- works end to end through the shipping code:
--
--   Pairing.decode -> providers/server.lua -> op.lua -> http.lua's WORKER
--   SOURCE -> the VENDORED luasocket http.lua -> a real TCP socket ->
--   server/server.js
--
-- Nothing in the protocol path is faked. The worker source is lifted
-- verbatim from mod/src/http.lua; luasocket is the engine's own vendored
-- copy (the same files the APK compiles), running over a dumb FFI TCP core
-- (tests/android_socket_core.lua). A fake that merely acted like luasocket
-- is exactly how the "HTTP 1" bug shipped -- the library's real return
-- convention is the thing under test.
--
-- Driven by tests/android.e2e.test.js, which boots the server and passes:
--
--   luajit tests/android.e2e_client.lua <setupCodeFile> <luasocketDir>
--
-- <luasocketDir> is the vendored libluasocket directory inside a gen1recomp
-- checkout (mobile/android/love/src/jni/love/src/libraries/luasocket/
-- libluasocket).

local setupCodeFile, luasocketDir = ...
assert(setupCodeFile and luasocketDir,
  "usage: luajit tests/android.e2e_client.lua <setupCodeFile> <luasocketDir>")

package.path = "./mod/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then passed = passed + 1
  else
    failed = failed + 1
    print("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want,
    ("got %s, want %s"):format(tostring(got), tostring(want)))
end

-- ------------------------------------------- the real vendored luasocket

local vendored = {
  ["socket.core"] = { file = nil },  -- the FFI core, local to this suite
  ["socket"]         = { file = "socket.lua" },
  ["ltn12"]          = { file = "ltn12.lua" },
  ["socket.url"]     = { file = "url.lua" },
  ["socket.headers"] = { file = "headers.lua" },
  ["socket.http"]    = { file = "http.lua" },
}

local loadedModules = {}
local realRequire = require

local function vendorRequire(name)
  if loadedModules[name] then return loadedModules[name] end
  if name == "socket.core" then
    loadedModules[name] = realRequire("tests.android_socket_core")
    return loadedModules[name]
  end
  if name == "mime" then
    -- A C module the vendored http.lua only reaches for proxy Basic auth,
    -- which this protocol never uses.
    loadedModules[name] = { b64 = function(s) return s end }
    return loadedModules[name]
  end
  local entry = vendored[name]
  if entry then
    local chunk = assert(loadfile(luasocketDir .. "/" .. entry.file))
    -- The vendored files require() their own siblings; feed those requires
    -- back through here so "socket" resolves to the vendored socket.lua.
    local env = setmetatable({ require = vendorRequire }, { __index = _G })
    setfenv(chunk, env)
    loadedModules[name] = chunk()
    return loadedModules[name]
  end
  return realRequire(name)
end

-- Sanity: this really is luasocket, speaking its real convention.
do
  local http = vendorRequire("socket.http")
  check("the vendored luasocket http module loads",
    type(http) == "table" and type(http.request) == "function")
end

-- --------------------------------------------------- the worker harness
--
-- Same mechanism as tests/e2e_client.lua: the worker source is lifted
-- verbatim and run against fake love.thread channels, so the code under
-- test is byte-for-byte what ships. The Android shape of it:
--   * require("https") fails            -- no lua-https in the APK
--   * require("socket.http") is REAL    -- the vendored library
--   * love.filesystem.load returns nil  -- so HostShell (curl) is absent

local httpSource = assert(io.open("mod/src/http.lua", "rb")):read("*a")
local WORKER_SOURCE = httpSource:match("%[==%[(.-)%]==%]")
assert(WORKER_SOURCE and #WORKER_SOURCE > 500,
  "could not lift WORKER_SOURCE out of mod/src/http.lua")

local channels = {}
local runWorker

local function getChannel(name)
  if channels[name] then return channels[name] end
  local q = {}
  local ch = {
    push = function(_, v)
      q[#q + 1] = v
      if name == "savesync_http_cmd" then runWorker() end
    end,
    pop = function() return table.remove(q, 1) end,
    peek = function() return q[1] end,
    demand = function() return table.remove(q, 1) end,
    clear = function() q = {} end,
  }
  channels[name] = ch
  return ch
end

runWorker = function()
  local env = setmetatable({
    require = function(name)
      if name == "https" then error("module 'https' not found", 2) end
      if name:sub(1, 5) == "love." then return true end
      return vendorRequire(name)
    end,
    love = {
      thread = { getChannel = function(n) return getChannel(n) end },
      filesystem = {
        load = function() return nil end,     -- no HostShell, no curl
        write = function() return false end,
        createDirectory = function() end,
        remove = function() end,
        getSaveDirectory = function() return "." end,
      },
      system = { getOS = function() return "Android" end },
    },
  }, { __index = _G })
  local chunk = assert(load(WORKER_SOURCE, "@worker"))
  setfenv(chunk, env)
  local ok, err = pcall(chunk)
  if not ok then print("worker crashed: " .. tostring(err)) end
end

-- --------------------------------------------- the mod, Android-shaped

local includeCache = {}
function SAVESYNC_INCLUDE(path)
  if includeCache[path] then return includeCache[path] end
  local chunk = assert(loadfile("mod/" .. path))
  includeCache[path] = chunk()
  return includeCache[path]
end

-- The main-thread side of http.lua reaches for love and require("https") /
-- require("socket.http") at load; give it the same Android shape. The
-- inline luasocket ALSO becomes available this way, which mirrors the
-- device: LOVE preloads luasocket into every Lua state it owns.
love = {
  thread = { newThread = function()
    return {
      start = function() end,
      isRunning = function() return true end,
      getError = function() return nil end,
    }
  end, getChannel = function(n) return getChannel(n) end },
  filesystem = {
    load = function() return nil end,
    write = function() return false end,
    createDirectory = function() end,
    remove = function() end,
    getSaveDirectory = function() return "." end,
  },
  system = { getOS = function() return "Android" end },
  timer = { getTime = os.clock },
}

local originalRequire = require
require = function(name)
  if name == "https" then error("module 'https' not found", 2) end
  if name == "socket.http" or name == "ltn12" then return vendorRequire(name) end
  return originalRequire(name)
end

local Http = SAVESYNC_INCLUDE("src/http.lua")
local Op = SAVESYNC_INCLUDE("src/op.lua")
local Pairing = SAVESYNC_INCLUDE("src/pairing.lua")
local Server = SAVESYNC_INCLUDE("src/providers/server.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")

require = originalRequire

-- ------------------------------------------------------- what Android is

check("the transport reports available", Http.available())
-- The caps probe needs one worker round trip; any poll drains it.
Http.release(Http.request({ url = "http://127.0.0.1:1/nothing" }))
eq("no TLS on this device -- GitHub and Dropbox are honestly out",
  Http.tlsCapable(), false)
local diag = Http.diagnostics()
check("diagnostics name the device", diag:find("Android", 1, true) ~= nil, diag)
check("diagnostics admit there is no curl", diag:find("curl: no", 1, true) ~= nil, diag)
check("diagnostics find the vendored sockets", diag:find("sockets: yes", 1, true) ~= nil, diag)

-- ------------------------------------------------- the provider, driven

local function run(op, what)
  for _ = 1, 4000 do
    local status, value = op:poll()
    if status ~= "pending" then return status, value end
  end
  return "error", what .. " never finished"
end

-- 1. The real setup code, as the server printed it.
local codeText = assert(io.open(setupCodeFile, "rb")):read("*a")
local pasted = Pairing.decode(codeText)
check("the server's setup code decodes", type(pasted) == "table", codeText)
eq("and names the server provider", pasted and pasted.provider, "server")

-- 2. Link -- one real round trip that proves URL and token.
local st, cfg = run(Server.link({ pasted = pasted }), "link")
eq("linking succeeds over vendored luasocket", st, "ok")
check("and the server introduced itself",
  type(cfg) == "table" and type(cfg.account) == "string",
  type(cfg) == "table" and cfg.account or cfg)

-- 3. Upload: a manifest plus a save payload CARRYING HOSTILE BYTES, shaped
-- exactly as the sync layer ships them (b64: prefix for the byte payload).
-- Every fixture in the first field bug was pure ASCII; never again.
local hostile = "return {\233\0\255 high=\128 nul=\0 quote=\"\\\" tail}"
local savedObject = "b64:" .. Util.b64(hostile)
local manifest = '{"device":"android-e2e","seq":1}'

st = run(Server.write(cfg, {
  ["manifest.json"] = manifest,
  ["red-e2e1234.sav"] = savedObject,
}), "write")
eq("upload lands", st, "ok")

-- 4. The listing sees both objects with true sizes.
local names
st, names = run(Server.list(cfg), "list")
eq("list answers", st, "ok")
check("the save is listed", type(names) == "table" and names["red-e2e1234.sav"] ~= nil)
eq("with its exact size", names and names["red-e2e1234.sav"], #savedObject)
check("the manifest is listed", names and names["manifest.json"] ~= nil)

-- 5. Device B: a fresh link from the same code, then a byte-exact download.
local st2, cfgB = run(Server.link({ pasted = Pairing.decode(codeText) }), "linkB")
eq("a second device links from the same code", st2, "ok")

local got
st, got = run(Server.read(cfgB, { "red-e2e1234.sav", "manifest.json" }), "read")
eq("download answers", st, "ok")
eq("the save arrives byte-identical", got and got["red-e2e1234.sav"], savedObject)
check("and decodes to the hostile original",
  got and Util.unb64(got["red-e2e1234.sav"]:sub(5)) == hostile)
eq("the manifest arrives intact", got and got["manifest.json"], manifest)

-- 6. A read of something absent is a 404, not an error -- half the sync
-- protocol is "is that object there".
st, got = run(Server.read(cfg, { "never-uploaded.sav" }), "read404")
eq("asking for a missing object still succeeds", st, "ok")
eq("and simply comes back empty", got and got["never-uploaded.sav"], nil)

-- 7. Deletion through the same batch endpoint.
st = run(Server.write(cfg, { ["red-e2e1234.sav"] = false }), "delete")
eq("deletion lands", st, "ok")
st, names = run(Server.list(cfg), "list2")
eq("and the listing agrees", names and names["red-e2e1234.sav"], nil)

-- 8. A wrong token is refused in the player's language, and the refusal
-- travels through the same real socket -- the 401 must arrive as a 401.
local bad = { url = cfg.url, token = "not-the-token" }
local stBad, errBad = run(Server.list(bad), "badToken")
eq("a wrong token fails", stBad, "error")
check("with the server's HTTP status readable in the message",
  tostring(errBad):find("401", 1, true) ~= nil
  or tostring(errBad):find("rejected", 1, true) ~= nil, errBad)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
