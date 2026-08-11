-- END-TO-END: two devices, the real HTTP worker, real curl, a real server.
--
-- Driven by tests/e2e.test.js, which boots the servers and passes their URLs
-- in.  Everything between the sync engine and the socket is the shipping
-- code:
--
--   sync.lua -> providers/server.lua -> op.lua -> http.lua's WORKER SOURCE
--   -> HostShell.popen -> curl -> server/server.js -> files on disk
--
-- The worker is not reimplemented here.  Its source is lifted verbatim out of
-- mod/src/http.lua and run against fake love.thread channels, so the request
-- this test sends is byte-for-byte the one the game sends.  HostShell.quote
-- is reproduced with the ENGINE'S REAL semantics, including the Windows
-- branch that deletes double quotes from an argument -- that behaviour is
-- exactly what the curl-config-file transport exists to survive.
--
--   luajit tests/e2e_client.lua <saveUrl> <token> <echoUrl> <workDir> [os]
--
-- The trailing argument picks which HostShell.quote branch to exercise --
-- "Windows" (quote-stripping) or "Linux"/"OS X" (single-quote escaping) --
-- so both platform paths are covered from whichever machine happens to be
-- running the suite.  It defaults to the real host OS.

local saveUrl, token, echoUrl, workDir, osName = ...
assert(saveUrl and token and echoUrl and workDir, "missing arguments")
osName = osName
  or (package.config:sub(1, 1) == "\\" and "Windows" or "Linux")

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

local IS_WINDOWS = osName == "Windows"
print("== quoting branch under test: " .. osName .. " ==")

-- --------------------------------------------------------- real-disk fs

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
      -- directories: cheap probe via a listing
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

-- ------------------------------------------------- HostShell, for real

-- Reproduces src/core/HostShell.lua's contract, INCLUDING the Windows quote
-- branch that strips double quotes instead of escaping them.
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
local runWorker   -- forward: the cmd channel runs it on push

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

-- Which device's disk the worker sees.  Swapped as the scenario moves
-- between devices, because the worker re-reads it on every run.
local activeFs

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
      }, { __index = function(_, k) return activeFs[k] end }),
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

-- ------------------------------------------------------------ devices

local function serialize(v, out)
  out = out or {}
  local t = type(v)
  if t == "table" then
    out[#out + 1] = "{"
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      out[#out + 1] = "[" .. string.format("%q", tostring(k)) .. "]="
      serialize(v[k], out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  else
    out[#out + 1] = tostring(v)
  end
  return table.concat(out)
end

local function newDevice(name, dirName)
  local dev = { name = name, root = workDir .. "/" .. dirName }
  dev.fs = makeFs(dev.root)
  local slots = { active = nil, list = {} }
  dev.saveData = {
    saveFilename = function(version)
      local a = slots.active
      return a and ("saves/" .. version .. "/" .. a .. ".lua") or nil
    end,
    activeSlot = function() return slots.active end,
    listSlots = function(version)
      local out = {}
      for _, id in ipairs(slots.list) do
        out[#out + 1] = { id = id,
          exists = dev.fs.getInfo("saves/" .. version .. "/" .. id .. ".lua") ~= nil }
      end
      return out
    end,
    createSlot = function()
      local id = "slot" .. (#slots.list + 1)
      slots.list[#slots.list + 1] = id
      return id
    end,
    setActiveSlot = function(_, id) slots.active = id end,
    writeSlot = function(version, slotId, tbl)
      return dev.fs.write("saves/" .. version .. "/" .. slotId .. ".lua",
        serialize(tbl))
    end,
    slotSummary = function(save)
      return (save.player and save.player.name), { badges = save.badges or 0 }
    end,
  }
  dev.serializer = {
    encode = serialize,
    decode = function(s)
      local chunk = load("return " .. s)
      if not chunk then return nil end
      local ok, v = pcall(chunk)
      return ok and v or nil
    end,
  }
  dev.gameVersion = {
    info = function(id) return id == "red" end,
    get = function() return "red" end,
  }
  dev.cache = {}
  dev.include = function(path)
    if dev.cache[path] then return dev.cache[path] end
    local chunk = assert(loadfile("mod/" .. path))
    local v = chunk()
    dev.cache[path] = v
    return v
  end
  return dev
end

local function activate(dev)
  activeFs = dev.fs
  _G.love = {
    filesystem = dev.fs,
    thread = {
      getChannel = getChannel,
      newThread = function()
        return { start = function() end, isRunning = function() return true end,
                 getError = function() return nil end }
      end,
    },
    system = { getOS = function() return osName end },
    timer = { getTime = function() return os.clock() end },
  }
  _G.SAVESYNC_INCLUDE = dev.include
  package.loaded["src.core.SaveData"] = dev.saveData
  package.loaded["src.core.SaveSerializer"] = dev.serializer
  package.loaded["src.core.GameVersion"] = dev.gameVersion
  if not dev.Sync then
    dev.Http = dev.include("src/http.lua")
    dev.Store = dev.include("src/store.lua")
    dev.Sync = dev.include("src/sync.lua")
    local c = dev.Store.config()
    c.provider = "server"
    c.cfg = { provider = "server", url = saveUrl, token = token }
    c.deviceName = dev.name
    dev.Store.saveConfig(c)
  end
  return dev
end

local function play(dev, tbl)
  activate(dev)
  local slot = dev.saveData.activeSlot()
  if not slot then
    slot = dev.saveData.createSlot("red")
    dev.saveData.setActiveSlot("red", slot)
  end
  dev.saveData.writeSlot("red", slot, tbl)
end

local function pump(dev, label)
  activate(dev)
  for _ = 1, 4000 do
    dev.Sync.update()
    if not dev.Sync.busy() then break end
  end
  if dev.Sync.state == "error" then
    print("  (" .. label .. " error: " .. tostring(dev.Sync.status) .. ")")
  end
  return dev.Sync.state
end

local function sync(dev)
  activate(dev)
  dev.Sync.request(true)
  return pump(dev, dev.name)
end

local function localSave(dev)
  activate(dev)
  local rec = dev.Store.readLocal("red")
  return rec and rec.save or nil
end

-- ------------------------------------------------------- the scenario

local A = newDevice("Device A", "devA")
local B = newDevice("Device B", "devB")

print("-- device A uploads over real HTTP")
play(A, { version = "red", player = { name = "RED" }, badges = 1,
          meta = { playthroughId = "E2E00001", savedAt = 100 } })
eq("A syncs cleanly", sync(A), "idle")

print("-- device B adopts it")
eq("B syncs cleanly", sync(B), "idle")
local bs = localSave(B)
check("B received a save", bs ~= nil)
eq("B got the player name", bs and bs.player.name, "RED")
eq("B got the badge count", bs and bs.badges, 1)

print("-- A moves on, B follows")
play(A, { version = "red", player = { name = "RED" }, badges = 2,
          meta = { playthroughId = "E2E00001", savedAt = 200 } })
eq("A uploads the update", sync(A), "idle")
eq("B downloads it", sync(B), "idle")
eq("B is up to date", localSave(B).badges, 2)

print("-- both change the same save while apart")
play(A, { version = "red", player = { name = "RED" }, badges = 3,
          meta = { playthroughId = "E2E00001", savedAt = 300 } })
play(B, { version = "red", player = { name = "RED" }, badges = 7,
          meta = { playthroughId = "E2E00001", savedAt = 310 } })
eq("A publishes first", sync(A), "idle")
eq("B refuses to guess", sync(B), "conflict")
eq("B kept its own save", localSave(B).badges, 7)
eq("A kept its own save", localSave(A).badges, 3)

print("-- the player keeps device B")
activate(B)
B.Sync.runForeground(B.Sync.resolveKeepLocal("red-E2E00001"),
  "Uploading...", "Kept this device")
eq("B resolved", pump(B, "B resolve"), "idle")
eq("A catches up to B", sync(A), "idle")
eq("A took B's version", localSave(A).badges, 7)

print("-- A's overwritten save is still recoverable")
activate(A)
local backups = A.Store.listBackups("red-E2E00001")
check("A backed up what it replaced", #backups > 0, "#backups=" .. #backups)

local hist
activate(A)
local histOp = A.Sync.history("red-E2E00001")
for _ = 1, 4000 do
  local st, v = histOp:poll()
  if st ~= "pending" then hist = (st == "ok") and v or nil break end
end
check("cloud history is readable", type(hist) == "table" and #hist > 0,
  "hist=" .. tostring(hist and #hist))

print("-- a JSON header survives the transport (the Dropbox case)")
activate(A)
local ARG = '{"path":"/red-E2E00001.sav","mode":"overwrite","mute":true}'
local job = A.Http.request({
  method = "POST",
  url = echoUrl,
  headers = { ["Dropbox-API-Arg"] = ARG, ["Content-Type"] = "application/octet-stream" },
  body = "some save bytes",
})
local res
for _ = 1, 4000 do
  res = A.Http.poll(job)
  if res.status ~= "pending" then break end
end
eq("echo request succeeded", res.status, "ok")
eq("echo returned 200", res.code, 200)

-- Decode rather than substring-match: the echo server JSON-encodes what it
-- received, so an intact header comes back with its quotes escaped and a
-- naive `find` would report a false failure.
local Json = A.include("src/json.lua")
local echoed = Json.decode(res.body or "") or {}
local seen = (echoed.headers or {})["dropbox-api-arg"]
eq("the JSON header arrived byte-identical", seen, ARG)
eq("the body arrived intact", echoed.body, "some save bytes")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
