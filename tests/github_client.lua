-- GITHUB PROVIDER, DRIVEN FOR REAL: the device-flow link, then read / write /
-- list, against a fake GitHub, through the real HTTP worker and real curl.
--
-- Driven by tests/github.test.js, which boots the fake GitHub server and
-- passes its URL in.  Same trick as tests/e2e_client.lua, aimed at the
-- GitHub provider instead of the sync engine:
--
--   providers/github.lua -> op.lua -> http.lua's WORKER SOURCE
--   -> HostShell.popen -> curl -> the fake server -> an in-memory gist
--
-- The worker is not reimplemented here.  Its source is lifted verbatim out
-- of mod/src/http.lua and run against fake love.thread channels, so the
-- request this test sends -- headers, body, the lot -- is byte-for-byte the
-- one the game would send.  Nothing between the provider and the socket is
-- stubbed; only GitHub itself is fake.
--
--   luajit tests/github_client.lua <fakeGithubUrl> <workDir>
--
-- One fake server answers both api.github.com's paths (/gists, /user) and
-- github.com's (/login/device/code, /login/oauth/access_token): the two
-- namespaces never collide, and a real GitHub setup needs two hostnames
-- only because it is two real services, not because the provider cares.

local baseUrl, workDir = ...
assert(baseUrl and workDir, "missing arguments")

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
  check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end

local osName = package.config:sub(1, 1) == "\\" and "Windows" or "Linux"
local IS_WINDOWS = osName == "Windows"

-- --------------------------------------------------------- real-disk fs
--
-- The http worker stages every request body and every curl config file on
-- disk (see mod/src/http.lua) -- that is deliberate product behaviour, not
-- a test convenience, so the stub here is a real filesystem rather than an
-- in-memory table.  Lifted verbatim from tests/e2e_client.lua.

local SEP = package.config:sub(1, 1)

local function mkdirp(path)
  local osPath = path:gsub("/", SEP)
  if SEP == "\\" then
    os.execute('mkdir "' .. osPath .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. osPath .. '" 2>/dev/null')
  end
end

local function listDir(path)
  local out = {}
  local cmd = SEP == "\\"
    and ('dir /b "' .. path:gsub("/", SEP) .. '" 2>nul')
    or ('ls -1 "' .. path .. '" 2>/dev/null')
  local p = io.popen(cmd)
  if not p then return out end
  for line in p:lines() do
    if line ~= "" then out[#out + 1] = line end
  end
  p:close()
  return out
end

local function makeFs(root)
  mkdirp(root)
  local function full(p) return root .. "/" .. p end
  return {
    getSaveDirectory = function() return root end,
    getInfo = function(p)
      local f = io.open(full(p), "rb")
      if f then
        local size = f:seek("end")
        f:close()
        return { type = "file", size = size }
      end
      if #listDir(full(p)) > 0 then return { type = "directory" } end
      return nil
    end,
    read = function(p)
      local f = io.open(full(p), "rb")
      if not f then return nil end
      local d = f:read("*a")
      f:close()
      return d
    end,
    write = function(p, data)
      local dir = full(p):match("^(.*)/[^/]*$")
      if dir then mkdirp(dir) end
      local f = io.open(full(p), "wb")
      if not f then return false end
      f:write(data)
      f:close()
      return true
    end,
    remove = function(p) os.remove(full(p)) return true end,
    createDirectory = function(p) mkdirp(full(p)) return true end,
    getDirectoryItems = function(p) return listDir(full(p)) end,
  }
end

-- ------------------------------------------------------- HostShell, for real
--
-- Reproduces src/core/HostShell.lua's contract for real, on whichever host
-- is actually running the suite -- see tests/e2e_client.lua for why only the
-- host's own quoting branch can be tested honestly.

local HostShell = {
  haveCurl = function() return true end,
  quote = function(s)
    s = tostring(s)
    if IS_WINDOWS then return '"' .. s:gsub('"', "") .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end,
  popen = function(cmd) return io.popen(cmd) end,
  pclose = function(pipe) return pipe:close() end,
  httpGet = function() return nil, "not used in this test" end,
}

-- ------------------------------------- the worker, lifted from http.lua

local httpSource = assert(io.open("mod/src/http.lua", "rb")):read("*a")
local WORKER_SOURCE = httpSource:match("%[==%[(.-)%]==%]")
assert(WORKER_SOURCE and #WORKER_SOURCE > 500,
  "could not lift WORKER_SOURCE out of mod/src/http.lua")

local channels = {}
local runWorker

local function getChannel(name)
  if channels[name] then return channels[name] end
  local q = {}
  local ch
  ch = {
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

local fs = makeFs(workDir .. "/gh")

runWorker = function()
  local env = {
    require = function() end,
    love = {
      thread = { getChannel = function(n) return getChannel(n) end },
      filesystem = setmetatable({
        load = function(path)
          if path == "src/core/HostShell.lua" then
            return function() return HostShell end
          end
          return nil
        end,
      }, { __index = function(_, k) return fs[k] end }),
      system = { getOS = function() return osName end },
    },
    tostring = tostring, tonumber = tonumber, type = type, pcall = pcall,
    ipairs = ipairs, pairs = pairs, table = table, string = string, os = os,
    error = error, assert = assert, print = print, select = select,
  }
  local chunk = assert(load(WORKER_SOURCE, "@worker"))
  if setfenv then setfenv(chunk, env) end
  local ok, err = pcall(chunk)
  if not ok then print("worker crashed: " .. tostring(err)) end
end

-- ------------------------------------------------------------ environment

local cache = {}
function SAVESYNC_INCLUDE(path)
  if cache[path] then return cache[path] end
  local chunk = assert(loadfile("mod/" .. path))
  local v = chunk()
  cache[path] = v
  return v
end

_G.love = {
  filesystem = fs,
  thread = {
    getChannel = getChannel,
    newThread = function()
      return { start = function() end, isRunning = function() return true end,
               getError = function() return nil end }
    end,
  },
  system = { getOS = function() return osName end },
  -- op.lua's nowSeconds() wants this for Ctx:sleep's real-time deadline;
  -- os.clock() is monotonic enough for a same-process test.
  timer = { getTime = function() return os.clock() end },
}

local Github = SAVESYNC_INCLUDE("src/providers/github.lua")

local function drain(op, label)
  local status, value
  for _ = 1, 4000 do
    status, value = op:poll()
    if status ~= "pending" then break end
  end
  if status == "pending" then
    print("  (" .. label .. " never finished)")
  elseif status == "error" then
    print("  (" .. label .. " error: " .. tostring(value) .. ")")
  end
  return status, value
end

-- ------------------------------------------------------------- scenario
--
-- One fake server, one namespace for both GitHub hostnames: see the header
-- comment for why that is a faithful stand-in and not a shortcut.
local CLIENT_ID = "test-client-id"
local function opts()
  return { clientId = CLIENT_ID, apiBase = baseUrl, webBase = baseUrl }
end

print("-- device A signs in (device flow), creating the storage gist")
local stateA = {}
local opA = Github.link(stateA, opts())
local sawUserCode = false
local statusA, cfgA
for _ = 1, 4000 do
  statusA, cfgA = opA:poll()
  if stateA.userCode then sawUserCode = true end
  if statusA ~= "pending" then break end
end
check("A: link finished ok", statusA == "ok", cfgA)
check("A: the UI saw a device code mid-flow", sawUserCode)
eq("A: cfg provider", cfgA and cfgA.provider, "github")
check("A: cfg has a token", cfgA and cfgA.token ~= nil and cfgA.token ~= "")
check("A: cfg has a gist id", cfgA and cfgA.gist ~= nil)

if statusA ~= "ok" then
  print(("%d passed, %d failed"):format(passed, failed))
  os.exit(1)
end

print("-- a full sync-style write: the save, its manifest, one history entry")
-- This is the exact shape of the bug that reached a player: link() alone
-- only ever writes the README, so a suite that stops there proves nothing
-- about whether a save actually gets uploaded.
local SAVE = "return {player={name='RED'},party={},badges=1}"
local MANIFEST = '{"v":1,"key":"red-GH00001","hash":"deadbeef","seq":1}'
local wstatus = drain(Github.write(cfgA, {
  ["red-GH00001.sav"] = SAVE,
  ["red-GH00001.json"] = MANIFEST,
  ["red-GH00001.h0001.sav"] = SAVE,
}), "A: initial write")
eq("A: initial write ok", wstatus, "ok")

local lstatus, listing = drain(Github.list(cfgA), "A: list")
eq("A: list ok", lstatus, "ok")
check("A: README is still there", listing and listing["README.md"] ~= nil)
check("A: the save landed", listing and listing["red-GH00001.sav"] ~= nil)
check("A: the manifest landed", listing and listing["red-GH00001.json"] ~= nil)
check("A: the history entry landed", listing and listing["red-GH00001.h0001.sav"] ~= nil)

print("-- read returns real content; a missing file is absent, not an error")
local rstatus, rvals = drain(
  Github.read(cfgA, { "red-GH00001.sav", "does-not-exist.sav" }), "A: read")
eq("A: read ok", rstatus, "ok")
eq("A: read got the save bytes back byte-identical", rvals and rvals["red-GH00001.sav"], SAVE)
check("A: a name nobody wrote is simply absent",
  rvals ~= nil and rvals["does-not-exist.sav"] == nil)

print("-- two scratch files, so there is something to delete alongside a write")
drain(Github.write(cfgA, {
  ["scratch1.sav"] = "scratch-one",
  ["scratch2.sav"] = "scratch-two",
}), "A: scratch write")

print("-- a MIXED write: update a save and delete the history entry, one PATCH")
local SAVE2 = "return {player={name='RED'},party={},badges=2}"
local mstatus = drain(Github.write(cfgA, {
  ["red-GH00001.sav"] = SAVE2,
  ["red-GH00001.h0001.sav"] = false,
}), "A: mixed write")
eq("A: mixed write ok", mstatus, "ok")
local _, afterMixed = drain(Github.read(cfgA, { "red-GH00001.sav" }), "A: read after mixed")
eq("A: the update took", afterMixed and afterMixed["red-GH00001.sav"], SAVE2)
local _, listAfterMixed = drain(Github.list(cfgA), "A: list after mixed")
check("A: the deleted history entry is gone",
  listAfterMixed and listAfterMixed["red-GH00001.h0001.sav"] == nil)

print("-- an ALL-DELETIONS write: no `content` survives into the payload at all")
-- P.write splices deletions into the encoded JSON by string surgery (see the
-- '^{"files":{(.*)}}$' match): when every entry is a deletion, the captured
-- inner text is empty and the splice has to build the object from nothing
-- but null-valued keys. That is a different code path from the mixed write
-- above, and the one most likely to hand GitHub broken JSON if it is wrong.
local astatus = drain(Github.write(cfgA, {
  ["scratch1.sav"] = false,
  ["scratch2.sav"] = false,
}), "A: delete-only write")
eq("A: delete-only write ok", astatus, "ok")

local fstatus, finalListing = drain(Github.list(cfgA), "A: final list")
eq("A: final list ok", fstatus, "ok")
check("A: scratch1 is gone", finalListing and finalListing["scratch1.sav"] == nil)
check("A: scratch2 is gone", finalListing and finalListing["scratch2.sav"] == nil)
check("A: the real save is still there, not just the README",
  finalListing and finalListing["red-GH00001.sav"] ~= nil)
check("A: the manifest is still there",
  finalListing and finalListing["red-GH00001.json"] ~= nil)

print("-- device B signs in and finds A's gist, rather than making a second one")
local stateB = {}
local statusB, cfgB = drain(Github.link(stateB, opts()), "B: link")
eq("B: link finished ok", statusB, "ok")
eq("B: found A's gist rather than creating a new one", cfgB and cfgB.gist, cfgA.gist)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
