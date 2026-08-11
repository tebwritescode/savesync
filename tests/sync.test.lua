-- Two-device integration test for the sync engine.
--
--   luajit tests/sync.test.lua
--
-- Builds two independent "devices" -- each with its own in-memory
-- filesystem, its own copy of the mod's modules and its own config -- over
-- one shared in-memory cloud, then plays out the sequences that a real
-- player's two machines go through:
--
--   * device A saves and uploads
--   * device B, which has never seen the save, adopts it
--   * A saves again, B picks the change up
--   * BOTH change the save independently -> conflict, and NOTHING is
--     overwritten until a human answers
--   * either answer preserves the losing save, on one side or the other
--   * history accumulates and prunes without losing the current save
--
-- The cloud here is a plain table, which is exactly the contract the real
-- providers implement: a flat namespace of named blobs.

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

-- ------------------------------------------------------------- the cloud

local cloud = { files = {} }
local cloudCalls = { read = 0, write = 0, list = 0 }

-- ------------------------------------------------------------ a device

-- A minimal Lua table serializer, standing in for the engine's
-- SaveSerializer.  It only has to round-trip the shapes a save uses.
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

local function newDevice(name)
  local dev = { name = name, disk = {} }

  -- ---- love.filesystem over a flat table
  dev.love = {
    filesystem = {
      getInfo = function(p)
        if dev.disk[p] ~= nil then return { type = "file", size = #dev.disk[p] } end
        for k in pairs(dev.disk) do
          if k:sub(1, #p + 1) == p .. "/" then return { type = "directory" } end
        end
        return nil
      end,
      read = function(p) return dev.disk[p] end,
      write = function(p, d) dev.disk[p] = d return true end,
      remove = function(p) dev.disk[p] = nil return true end,
      createDirectory = function() return true end,
      getDirectoryItems = function(p)
        local out = {}
        for k in pairs(dev.disk) do
          local rest = k:match("^" .. p:gsub("%p", "%%%0") .. "/([^/]+)$")
          if rest then out[#out + 1] = rest end
        end
        table.sort(out)
        return out
      end,
    },
    math = { random = function(a, b) return math.random(a, b) end },
    timer = { getTime = function() return os.clock() end },
  }

  -- ---- the engine modules the store reaches for
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
          exists = dev.disk["saves/" .. version .. "/" .. id .. ".lua"] ~= nil }
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
      dev.disk["saves/" .. version .. "/" .. slotId .. ".lua"] = serialize(tbl)
      return true
    end,
    slotSummary = function(save)
      return (save.player and save.player.name), { badges = save.badges or 0 }
    end,
  }
  dev.slots = slots
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
    info = function(id) return id == "red" end,   -- one version keeps output small
    get = function() return "red" end,
  }

  -- ---- a fresh copy of the mod's modules, so each device has its own
  -- module-level state (the config cache in particular)
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

-- Point the globals at one device.  Modules are loaded lazily on first
-- activate, so each device binds to its own stubs.
local function activate(dev)
  _G.love = dev.love
  _G.SAVESYNC_INCLUDE = dev.include
  package.loaded["src.core.SaveData"] = dev.saveData
  package.loaded["src.core.SaveSerializer"] = dev.serializer
  package.loaded["src.core.GameVersion"] = dev.gameVersion
  if not dev.Sync then
    dev.Op = dev.include("src/op.lua")
    dev.Store = dev.include("src/store.lua")
    dev.Sync = dev.include("src/sync.lua")
    dev.Providers = dev.include("src/providers/init.lua")
    -- Register the fake cloud as a provider on THIS device's registry.
    local Op = dev.Op
    dev.Providers.get = function(id)
      if id ~= "fake" then return nil end
      return {
        id = "fake",
        describe = function() return "Fake cloud" end,
        exportable = function(cfg) return { provider = "fake", token = cfg.token } end,
        list = function()
          return Op.new(function()
            cloudCalls.list = cloudCalls.list + 1
            local out = {}
            for k, v in pairs(cloud.files) do out[k] = #v end
            return out
          end)
        end,
        read = function(_, names)
          return Op.new(function()
            cloudCalls.read = cloudCalls.read + 1
            local out = {}
            for _, n in ipairs(names) do out[n] = cloud.files[n] end
            return out
          end)
        end,
        write = function(_, files)
          return Op.new(function()
            cloudCalls.write = cloudCalls.write + 1
            for n, c in pairs(files) do
              if c == false then cloud.files[n] = nil else cloud.files[n] = c end
            end
            return true
          end)
        end,
      }
    end
    local c = dev.Store.config()
    c.provider, c.cfg = "fake", { provider = "fake", token = "t" }
    c.deviceName = dev.name
    dev.Store.saveConfig(c)
  end
  return dev
end

-- Write a save to the device's disk the way the game would.
local function play(dev, tbl)
  activate(dev)
  local slot = dev.saveData.activeSlot()
  if not slot then
    slot = dev.saveData.createSlot("red")
    dev.saveData.setActiveSlot("red", slot)
  end
  dev.saveData.writeSlot("red", slot, tbl)
end

-- Run one full sync cycle to completion.
local function sync(dev)
  activate(dev)
  dev.Sync.request(true)
  for _ = 1, 200 do
    dev.Sync.update()
    if not dev.Sync.busy() then break end
  end
  return dev.Sync.state, dev.Sync.status
end

local function localSave(dev)
  activate(dev)
  local rec = dev.Store.readLocal("red")
  return rec and rec.save or nil
end

local function cloudKeys()
  local out = {}
  for k in pairs(cloud.files) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- ------------------------------------------------------------ the story

local A = newDevice("Device A")
local B = newDevice("Device B")

-- 1. A plays and syncs.  Nothing in the cloud yet, so this is an upload.
play(A, { version = "red", player = { name = "RED" }, badges = 1,
          meta = { playthroughId = "PLAY0001", savedAt = 100 } })
local st = sync(A)
eq("A syncs cleanly", st, "idle")
check("cloud has the save", cloud.files["red-PLAY0001.sav"] ~= nil,
  table.concat(cloudKeys(), ", "))
check("cloud has a manifest", cloud.files["red-PLAY0001.json"] ~= nil)
check("cloud has a history entry", cloud.files["red-PLAY0001.h0001.sav"] ~= nil)

-- Only save-shaped names, ever.  This is the "never upload ROMs" guarantee
-- expressed as a test: the engine builds its upload set from save slots, so
-- there is no name in the cloud that did not come from one.
for _, k in ipairs(cloudKeys()) do
  check("cloud name is save-shaped: " .. k,
    k:match("^red%-PLAY0001%.[hjs]") ~= nil)
end

-- 2. B has never seen this playthrough.  Nothing local to lose -> adopt.
eq("B syncs cleanly", sync(B), "idle")
local bSave = localSave(B)
check("B now has the save", bSave ~= nil)
eq("B got the right save", bSave and bSave.player.name, "RED")
eq("B got the badge count", bSave and bSave.badges, 1)

-- 3. A plays on.  B picks the change up on its next sync.
play(A, { version = "red", player = { name = "RED" }, badges = 2,
          meta = { playthroughId = "PLAY0001", savedAt = 200 } })
eq("A uploads the update", sync(A), "idle")
eq("B downloads the update", sync(B), "idle")
eq("B is up to date", localSave(B).badges, 2)

-- 4. THE CASE THAT MATTERS.  Both devices change the same save without
-- syncing in between.  Neither may be overwritten.
play(A, { version = "red", player = { name = "RED" }, badges = 3,
          meta = { playthroughId = "PLAY0001", savedAt = 300 } })
play(B, { version = "red", player = { name = "RED" }, badges = 5,
          meta = { playthroughId = "PLAY0001", savedAt = 310 } })

eq("A publishes first", sync(A), "idle")
eq("B refuses to guess", sync(B), "conflict")
eq("B kept its own save untouched", localSave(B).badges, 5)
eq("A's save is still A's", localSave(A).badges, 3)
check("the cloud still holds A's version",
  cloud.files["red-PLAY0001.sav"]:find("3", 1, true) ~= nil)

-- B refuses again rather than drifting into a decision on a later cycle.
eq("B stays in conflict", sync(B), "conflict")
eq("B still has its save", localSave(B).badges, 5)

-- 5. The player answers: keep this device (B).  A's version is not lost --
-- it is in cloud history, where A put it.
activate(B)
B.Sync.runForeground(B.Sync.resolveKeepLocal("red-PLAY0001"),
  "Uploading...", "Kept this device")
for _ = 1, 200 do
  B.Sync.update()
  if not B.Sync.busy() then break end
end
eq("B resolved", B.Sync.state, "idle")
check("cloud now holds B's version",
  cloud.files["red-PLAY0001.sav"]:find("5", 1, true) ~= nil)

local historyHasA = false
for name, body in pairs(cloud.files) do
  if name:match("^red%-PLAY0001%.h%d+%.sav$") and body:find('"badges"%]=3') then
    historyHasA = true
  end
end
check("A's overwritten save survives in cloud history", historyHasA,
  table.concat(cloudKeys(), ", "))

-- 6. A comes back.  It is behind now, and behind-with-no-local-change is a
-- plain download.
eq("A catches up", sync(A), "idle")
eq("A took B's version", localSave(A).badges, 5)

-- The displaced save on A was backed up before it was replaced.
activate(A)
local backups = A.Store.listBackups("red-PLAY0001")
check("A backed up what it replaced", #backups > 0)

-- 7. History prunes but never touches the current save.
for badges = 6, 20 do
  play(A, { version = "red", player = { name = "RED" }, badges = badges,
            meta = { playthroughId = "PLAY0001", savedAt = 400 + badges } })
  sync(A)
end
local hist = 0
for name in pairs(cloud.files) do
  if name:match("^red%-PLAY0001%.h%d+%.sav$") then hist = hist + 1 end
end
check("history is bounded", hist <= 10, "kept " .. hist)
check("current save is still there", cloud.files["red-PLAY0001.sav"] ~= nil)
check("current save is the latest",
  cloud.files["red-PLAY0001.sav"]:find('"badges"%]=20') ~= nil)
eq("and it round-trips to A", localSave(A).badges, 20)

-- 8. Local backups are bounded too, and the newest is first.
activate(A)
local finalBackups = A.Store.listBackups("red-PLAY0001")
check("local backups are bounded", #finalBackups <= 10, "kept " .. #finalBackups)
if #finalBackups > 1 then
  check("newest backup first", finalBackups[1].name > finalBackups[2].name)
end

-- 9. MULTIPLE SAVE FILES.
--
-- Slots are independent playthroughs. Two things must hold: all of them sync
-- (not just whichever is selected), and a save arriving from the cloud lands
-- in the slot that holds ITS playthrough -- never in whichever slot happens
-- to be active, which would destroy an unrelated game.

local function playIn(dev, slotId, tbl)
  activate(dev)
  local known = false
  for _, id in ipairs(dev.slots.list) do
    if id == slotId then known = true end
  end
  if not known then dev.slots.list[#dev.slots.list + 1] = slotId end
  dev.saveData.writeSlot("red", slotId, tbl)
end

local C = newDevice("Device C")
playIn(C, "slot1", { version = "red", player = { name = "ASH" }, badges = 4,
  meta = { playthroughId = "PLAYAAAA", savedAt = 900 } })
playIn(C, "slot2", { version = "red", player = { name = "GARY" }, badges = 6,
  meta = { playthroughId = "PLAYBBBB", savedAt = 910 } })
activate(C)
C.slots.active = "slot1"

eq("C syncs both files", sync(C), "idle")
check("first playthrough reached the cloud",
  cloud.files["red-PLAYAAAA.sav"] ~= nil, table.concat(cloudKeys(), ", "))
check("second playthrough reached the cloud",
  cloud.files["red-PLAYBBBB.sav"] ~= nil, table.concat(cloudKeys(), ", "))

-- A fresh device takes both down, into two separate slots.
local D2 = newDevice("Device D")
eq("D syncs cleanly", sync(D2), "idle")
activate(D2)
local dSlots = {}
for _, s in ipairs(D2.saveData.listSlots("red")) do
  local rec = D2.Store.readSlot("red", s.id)
  if rec then dSlots[rec.key] = rec.save.badges end
end
eq("D adopted the first playthrough", dSlots["red-PLAYAAAA"], 4)
eq("D adopted the second playthrough", dSlots["red-PLAYBBBB"], 6)

-- The invariant that matters is ONE SLOT PER PLAYTHROUGH -- not a fixed
-- count, since this shared cloud also still holds the playthrough from the
-- conflict scenario above, and adopting that one too is correct.
local function slotsAndKeys(dev)
  activate(dev)
  local slots = dev.saveData.listSlots("red")
  local keys = {}
  local n = 0
  for _, s in ipairs(slots) do
    local rec = dev.Store.readSlot("red", s.id)
    if rec and not keys[rec.key] then keys[rec.key] = true n = n + 1 end
  end
  return #slots, n
end

local dSlotCount, dKeyCount = slotsAndKeys(D2)
eq("D made one slot per playthrough, no duplicates", dSlotCount, dKeyCount)
check("D adopted every cloud playthrough", dKeyCount >= 3, "keys=" .. dKeyCount)

-- THE OVERWRITE TEST. Device C is sitting on slot1 (PLAYAAAA). Device D
-- advances the OTHER playthrough and publishes it. C must put that update in
-- slot2 and leave the slot it is looking at completely alone.
local before = nil
activate(C)
before = C.Store.readSlot("red", "slot1").bytes

-- activate FIRST: the modules are per-device but the love global is not, so
-- reading D's store while C is active would read C's disk through D's code.
activate(D2)
local dSlotForB
for _, s in ipairs(D2.saveData.listSlots("red")) do
  local rec = D2.Store.readSlot("red", s.id)
  if rec and rec.key == "red-PLAYBBBB" then dSlotForB = s.id end
end
check("found D's slot for the second playthrough", dSlotForB ~= nil)
playIn(D2, dSlotForB, { version = "red", player = { name = "GARY" }, badges = 8,
  meta = { playthroughId = "PLAYBBBB", savedAt = 920 } })
eq("D publishes the second playthrough", sync(D2), "idle")

activate(C)
C.slots.active = "slot1"
eq("C takes the update", sync(C), "idle")
eq("C updated the right slot", C.Store.readSlot("red", "slot2").save.badges, 8)
eq("C left the selected slot untouched",
  C.Store.readSlot("red", "slot1").bytes, before)
local cSlotCount, cKeyCount = slotsAndKeys(C)
eq("C still holds one slot per playthrough", cSlotCount, cKeyCount)

-- 10. Uploading also leaves a local copy, so a single-device player has
-- something in Restore Previous Save without ever having been overwritten.
activate(C)
check("an upload leaves a local backup",
  #C.Store.listBackups("red-PLAYAAAA") > 0)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
