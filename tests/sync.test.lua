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
        -- Immediate children only, same as real love.filesystem -- a leaf
        -- file returns its own name, but a deeper path (savesync/snapshots
        -- has a key directory below it, which has the .snap files below
        -- THAT) has to collapse to just the next segment, or a caller that
        -- lists the top level to discover subdirectories -- Snapshot.allLocal
        -- does exactly this -- would always see nothing.
        local out, seen = {}, {}
        local prefix = p .. "/"
        for k in pairs(dev.disk) do
          if k:sub(1, #prefix) == prefix then
            local first = k:sub(#prefix + 1):match("^([^/]+)")
            if first and not seen[first] then
              seen[first] = true
              out[#out + 1] = first
            end
          end
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

  -- ---- a fake mod.checkpoints, standing in for the engine's real
  -- Checkpoint.lua.  `settled` mirrors the engine's settled-overworld gate;
  -- flipping it is how these tests exercise a refusal without needing a
  -- real overworld, a real map or a real animation flag to fake one.  The
  -- identity fields default to matching what `play()` writes below, so a
  -- device that never touches snapshots at all just carries an unused stub.
  dev.checkpointState = { settled = true, version = "red",
    playthroughId = "PLAY0001", badges = 0 }
  dev.checkpoints = {
    inspect = function(_, _game)
      local st = dev.checkpointState
      if not st.settled then
        return { canCapture = false, canRestore = false,
          message = "Close the active menu or screen before creating a checkpoint." }
      end
      return { canCapture = true, canRestore = true, kind = "overworld" }
    end,
    capture = function(_, _game)
      local st = dev.checkpointState
      if not st.settled then
        return nil, "screen_busy",
          "Close the active menu or screen before creating a checkpoint."
      end
      return {
        format = 1,
        kind = "overworld",
        identity = { engineVersion = "test", gameVersion = st.version,
          playthroughId = st.playthroughId },
        save = { badges = st.badges or 0 },
        runtime = { overworld = { map = "pallet", x = 10, y = 10,
          facing = "down", surfing = false } },
      }
    end,
    restore = function(_, _game, checkpoint)
      local st = dev.checkpointState
      if not st.settled then
        return false, "screen_busy",
          "Close the active menu or screen before creating a checkpoint."
      end
      if checkpoint.identity.gameVersion ~= st.version
          or checkpoint.identity.playthroughId ~= st.playthroughId then
        return false, "wrong_playthrough", "Checkpoint belongs to another playthrough."
      end
      st.badges = checkpoint.save.badges
      dev.restoreCount = (dev.restoreCount or 0) + 1
      return true
    end,
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
    dev.Snapshot = dev.include("src/snapshot.lua")
    dev.Snapshot.bind({ checkpoints = dev.checkpoints })
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

-- Cloud payloads are base64 on the wire (see the blob-encoding note in
-- sync.lua), so every assertion about what the cloud HOLDS has to decode
-- first. Going through Sync.decodeBlob rather than a local base64 copy means
-- these checks also prove the shipping decoder is the inverse of the encoder.
local function cloudSave(dev, name)
  activate(dev)
  return dev.Sync.decodeBlob(cloud.files[name]) or ""
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
  cloudSave(A, "red-PLAY0001.sav"):find("3", 1, true) ~= nil)

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
  cloudSave(A, "red-PLAY0001.sav"):find("5", 1, true) ~= nil)

local historyHasA = false
for name, body in pairs(cloud.files) do
  if name:match("^red%-PLAY0001%.h%d+%.sav$")
      and (A.Sync.decodeBlob(body) or ""):find('"badges"%]=3') then
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
  cloudSave(A, "red-PLAY0001.sav"):find('"badges"%]=20') ~= nil)
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

-- 11. AUTOSAVE.
--
-- The gate is the whole feature. An autosave that fires during a battle, a
-- cutscene or a warp writes a state the player did not choose, and in Gen 1
-- an autosave that fires at all when they meant to soft-reset destroys a
-- legitimate technique. So: off by default, and every refusal tested.

activate(A)
local Autosave = A.include("src/autosave.lua")

eq("autosave is off by default", Autosave.minutes(), 0)
eq("autosave label reads OFF", Autosave.label(), "OFF")

-- A fake game whose stack top and flags we can move around.
local overworld = { player = { moving = false } }
local fakeGame = {
  overworld = overworld,
  save = { version = "red" },
  stack = { states = { overworld }, top = function(s) return s.states[#s.states] end },
  writeSave = function() return true end,
}

check("safe when settled in the overworld", Autosave.safe(fakeGame) == true)

-- A menu, a battle, a shop -- anything pushed above the overworld.
table.insert(fakeGame.stack.states, { screenId = "SomeMenu" })
check("not safe with a menu open", Autosave.safe(fakeGame) == false)
table.remove(fakeGame.stack.states)

overworld.transitioning = true
check("not safe mid-warp", Autosave.safe(fakeGame) == false)
overworld.transitioning = nil

overworld.runner = { isRunning = function() return true end }
check("not safe during a script", Autosave.safe(fakeGame) == false)
overworld.runner = nil

overworld.player.moving = true
check("not safe mid-step", Autosave.safe(fakeGame) == false)
overworld.player.moving = false

check("safe again once settled", Autosave.safe(fakeGame) == true)

-- The engine's own gate wins when it is present.  Everything above exercised
-- the fallback (there is no src.render.Zoom in a pure-Lua test), so this
-- proves the real predicate is the one consulted in a real build.
package.loaded["src.render.Zoom"] = {
  gateOK = function() return false end,
}
check("the engine gate is consulted when available",
  Autosave.safe(fakeGame) == false)
package.loaded["src.render.Zoom"] = nil

-- Off means off: no write, however long has passed.
local wrote = 0
fakeGame.writeSave = function() wrote = wrote + 1 return true end
Autosave.setMinutes(0)
Autosave.noteSaved()
for _ = 1, 5 do Autosave.update(fakeGame) end
eq("off never writes", wrote, 0)

-- Now the part that matters: that update() actually OBEYS the gate. Testing
-- safe() alone would pass even if update() never called it, so drive the
-- clock forward and watch what update() does with it.
local fakeNow = 100000
_G.love.timer.getTime = function() return fakeNow end

wrote = 0
Autosave.setMinutes(3)
Autosave.update(fakeGame)
eq("no write before the interval is up", wrote, 0)

fakeNow = fakeNow + 200          -- 3 min 20 s later: due
overworld.player.moving = true   -- ...but the player is mid-step
Autosave.update(fakeGame)
eq("a due save waits while unsafe", wrote, 0)

table.insert(fakeGame.stack.states, { screenId = "Battle" })
Autosave.update(fakeGame)
eq("a due save waits through a battle", wrote, 0)
table.remove(fakeGame.stack.states)

overworld.player.moving = false  -- settled at last
Autosave.update(fakeGame)
eq("the deferred save lands as soon as it is safe", wrote, 1)

Autosave.update(fakeGame)
eq("and does not immediately write again", wrote, 1)

fakeNow = fakeNow + 200
Autosave.update(fakeGame)
eq("writes again after another interval", wrote, 2)

-- A veto (the save.write hook, an ephemeral tool session) is an answer, not
-- an error: back off instead of retrying every frame.
fakeGame.writeSave = function() wrote = wrote + 1 return false end
fakeNow = fakeNow + 200
Autosave.update(fakeGame)
local afterVeto = wrote
for _ = 1, 20 do Autosave.update(fakeGame) end
eq("a veto backs off instead of spinning", wrote, afterVeto)

fakeGame.writeSave = function() wrote = wrote + 1 return true end
Autosave.setMinutes(0)

-- The cycle walks the offered choices and comes back to off.
local seen = {}
for _ = 1, #Autosave.CHOICES do
  Autosave.cycle()
  seen[#seen + 1] = Autosave.minutes()
end
eq("cycling returns to off", seen[#seen], 0)
check("cycling offers a real interval", seen[1] > 0)

-- ------------------------------------------------------------ snapshots
--
-- Snapshots stand in for the engine's mod.checkpoints, faked per device
-- above (dev.checkpoints / dev.checkpointState).  They are append-only --
-- see the comment atop sync.lua -- so what needs testing here is different
-- from the save story: that the timer only fires when the engine allows it,
-- that the two auto timers default to opposite states for opposite reasons,
-- that a snapshot's cloud name survives the self-hosted server's own name
-- rule, that snapshots propagate device to device, that pruning caps at
-- ten on both sides, and that restoring one is itself undoable.

-- 12. A SNAPSHOT IS TAKEN WHEN DUE, AND NOT WHEN THE ENGINE REFUSES.
local E = newDevice("Device E")
activate(E)

local okName, okKey = E.Snapshot.take(nil, "manual")
check("a snapshot is taken when the engine allows it", okName ~= nil, okKey)
eq("its key is version + playthrough, same shape saves use", okKey, "red-PLAY0001")

E.checkpointState.settled = false
local refusedName, refusedMsg = E.Snapshot.take(nil, "manual")
check("no snapshot when the engine refuses", refusedName == nil)
eq("the engine's own refusal message passes through verbatim", refusedMsg,
  "Close the active menu or screen before creating a checkpoint.")
E.checkpointState.settled = true

-- 13. THE TWO AUTO TIMERS, AND THE TIMER-LEVEL REFUSAL/DEFERRAL.
local Autosave2 = E.include("src/autosave.lua")
eq("auto snapshot defaults to 5", Autosave2.snapshotMinutes(), 5)
eq("auto snapshot label reads 5 min", Autosave2.snapshotLabel(), "5 min")
eq("auto save-file still defaults to 0", Autosave2.minutes(), 0)
eq("auto save-file label still reads OFF", Autosave2.label(), "OFF")

local fakeSnapNow = 500000
_G.love.timer.getTime = function() return fakeSnapNow end
Autosave2.setSnapshotMinutes(5)   -- lastSnapshotAt = fakeSnapNow, from here

local key13 = "red-PLAY0001"
local before13 = #E.Snapshot.list(key13)
Autosave2.update({})
eq("no snapshot before the interval is up", #E.Snapshot.list(key13), before13)

fakeSnapNow = fakeSnapNow + 301        -- 5 min 1 s later: due
E.checkpointState.settled = false
Autosave2.update({})
eq("a due snapshot waits while the engine refuses",
  #E.Snapshot.list(key13), before13)

E.checkpointState.settled = true
Autosave2.update({})
eq("the deferred snapshot lands once the engine allows it",
  #E.Snapshot.list(key13), before13 + 1)

Autosave2.update({})
eq("and does not immediately fire again", #E.Snapshot.list(key13), before13 + 1)

-- A capture failure (not just "not settled yet") is a veto too, and backs
-- off instead of retrying every frame -- same reasoning as the save-file
-- veto in section 11, exercised here for the second timer.
local realCapture = E.checkpoints.capture
E.checkpoints.capture = function() return nil, "capture_failed", "boom" end
fakeSnapNow = fakeSnapNow + 301
Autosave2.update({})
local afterFirstFail = #E.Snapshot.list(key13)
eq("a capture failure writes nothing", afterFirstFail, before13 + 1)
for _ = 1, 20 do Autosave2.update({}) end
eq("and backs off instead of spinning", #E.Snapshot.list(key13), afterFirstFail)
E.checkpoints.capture = realCapture

-- 14 & 15. CLOUD NAMES, AND PROPAGATION DEVICE A -> CLOUD -> DEVICE B.
--
-- No conflict handling needed for any of this -- see the comment atop
-- sync.lua -- so this checks that the files actually MOVE: what E holds
-- locally reaches the cloud under a name the self-hosted server's own
-- validator accepts, and a device that has never seen them adopts every one.

-- Mirrors server/server.js's NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
-- plus its explicit rejection of "..".  Re-implemented here, not imported,
-- so a mismatch on EITHER side of the wire fails this test, not just a typo
-- both sides happen to share.
local function validCloudName(name)
  if type(name) ~= "string" or name == "" or #name > 128 then return false end
  if not name:match("^%w") then return false end
  if name:find("%.%.", 1, true) then return false end
  return name:match("^[%w][%w%._%-]*$") == name
end

-- The precise shape sync.lua's snapCloudName/parseSnapName agree on for
-- key13, not just "starts with the key plus .s" -- the shared cloud already
-- holds "red-PLAY0001.sav" from the save story earlier in this file, and
-- that name starts with "red-PLAY0001.s" too.
local function isKey13Snapshot(name)
  return name:match("^red%-PLAY0001%.s%d+%-%d+%-%x+%.snap$") ~= nil
end

activate(E)
local eSnapsBefore = E.Snapshot.list(key13)
check("device E has snapshots to sync", #eSnapsBefore > 0)
eq("device E syncs cleanly", sync(E), "idle")

local snapCloudCount = 0
for name in pairs(cloud.files) do
  if isKey13Snapshot(name) then snapCloudCount = snapCloudCount + 1 end
end
eq("every local snapshot reached the cloud", snapCloudCount, #eSnapsBefore)

local sawSnapName = false
for name in pairs(cloud.files) do
  if name:find("%.snap$") then
    sawSnapName = true
    check("snapshot cloud name matches the server's validator: " .. name,
      validCloudName(name))
  end
end
check("at least one snapshot cloud name was checked", sawSnapName)

local F = newDevice("Device F")
activate(F)
eq("device F syncs cleanly", sync(F), "idle")
local fSnaps = F.Snapshot.list(key13)
eq("device F adopted every snapshot", #fSnaps, #eSnapsBefore)

-- 16. PRUNING KEEPS THE NEWEST TEN, LOCALLY AND IN THE CLOUD.
--
-- A device and a playthrough id of its own: key13 already carries the
-- handful of snapshots section 17 below depends on still being present, and
-- names taken within the same wall-clock second sort by hash, not by true
-- creation order (see snapshot.lua's own comment on why the hash is there),
-- so hammering key13 with fifteen more here could evict one of those on
-- nothing more than a tie-break.  A fresh key sidesteps the question.
local G = newDevice("Device G")
activate(G)
G.checkpointState.playthroughId = "PLAYPRUNE"
local keyPrune = "red-PLAYPRUNE"
local function isPruneSnapshot(name)
  return name:match("^red%-PLAYPRUNE%.s%d+%-%d+%-%x+%.snap$") ~= nil
end

-- Sync after EVERY take, not once at the end.  Local pruning caps the disk
-- at ten regardless, so a single sync at the end would only ever have ten
-- files to offer and would pass even with cloud-side pruning deleted
-- outright.  Syncing every time is what makes the cloud accumulate past ten
-- unless ITS OWN prune (the thing actually under test here) trims it back.
local lastSyncState
for i = 1, 15 do
  G.checkpointState.badges = 100 + i    -- distinct content each time, so
  G.Snapshot.take(nil, "manual")        -- rapid calls do not collide on name
  lastSyncState = sync(G)
end
eq("every incremental sync stayed clean", lastSyncState, "idle")
local localCount16 = #G.Snapshot.list(keyPrune)
check("local snapshots are capped at ten", localCount16 <= 10,
  "kept " .. localCount16)

local cloudCount16 = 0
for name in pairs(cloud.files) do
  if isPruneSnapshot(name) then cloudCount16 = cloudCount16 + 1 end
end
check("cloud snapshots are capped at ten too", cloudCount16 <= 10,
  "kept " .. cloudCount16)

-- 17. RESTORING A SNAPSHOT TAKES A RECOVERY ONE FIRST.
--
-- snapshot.lua's own comment says why: Checkpoint.restore rolls back in
-- memory on failure, but a caller wanting durable crash recovery has to
-- capture its own -- so Snapshot.restore does, unconditionally, before it
-- ever asks the engine to restore anything.  The engine side is a fake
-- here; what is under test is that Snapshot.restore's own ordering holds.
activate(E)
E.checkpointState.badges = 777
local marked = E.Snapshot.take(nil, "manual")
check("a marker snapshot exists to restore", marked ~= nil)

E.checkpointState.badges = 888   -- distinct, so the recovery capture cannot
                                  -- be mistaken for one already on disk
local ok17, err17 = E.Snapshot.restore(nil, key13, marked)
check("restore reports success", ok17, err17)

local sawRecovery = false
for _, row in ipairs(E.Snapshot.list(key13)) do
  local rec = E.Snapshot.decode(E.Snapshot.readRaw(key13, row.name))
  if rec and rec.tag == "undo" and rec.checkpoint.save.badges == 888 then
    sawRecovery = true
  end
end
check("a recovery snapshot (tagged 'undo') was taken before restoring",
  sawRecovery)

-- Even a restore the engine itself refuses still leaves that recovery
-- snapshot behind -- Snapshot.take happens unconditionally before the
-- engine is ever asked, not only when the engine is about to say yes.
local realRestore = E.checkpoints.restore
E.checkpoints.restore = function() return false, "restore_failed", "no." end
E.checkpointState.badges = 999
local okFail, errFail = E.Snapshot.restore(nil, key13, marked)
check("a restore the engine refuses reports failure", okFail == false)
eq("with the engine's own message", errFail, "no.")
local sawFailRecovery = false
for _, row in ipairs(E.Snapshot.list(key13)) do
  local rec = E.Snapshot.decode(E.Snapshot.readRaw(key13, row.name))
  if rec and rec.tag == "undo" and rec.checkpoint.save.badges == 999 then
    sawFailRecovery = true
  end
end
check("a recovery snapshot was captured even though the restore failed",
  sawFailRecovery)
E.checkpoints.restore = realRestore

-- --------------------------------------------------------------- wrap
--
-- Util.wrap is what stands between a long engine or provider message and a
-- player who cannot read it -- see mod/src/ui.lua's file header.  Tested
-- directly here because ui.lua itself needs real font sheets to render.

activate(A)
local Util = A.include("src/util.lua")

eq("wrap: short text is one line", #Util.wrap("hello", 19), 1)
eq("wrap: lossless when it fits on one line", Util.wrap("hello", 19)[1], "hello")

local longText = "the quick brown fox jumps over the lazy dog"
local wrapped = Util.wrap(longText, 10)
local widest = 0
for _, line in ipairs(wrapped) do widest = math.max(widest, #line) end
check("wrap: never exceeds the requested width", widest <= 10, widest)
eq("wrap: lossless when rejoined", table.concat(wrapped, " "), longText)

local oneLongWord = "supercalifragilisticexpialidocious"
local brokenWord = Util.wrap(oneLongWord, 10)
check("wrap: a single over-long word is hard-broken, not left overflowing",
  #brokenWord > 1)
local widestWord = 0
for _, line in ipairs(brokenWord) do widestWord = math.max(widestWord, #line) end
check("wrap: hard-broken chunks still respect the width", widestWord <= 10,
  widestWord)
eq("wrap: hard-broken chunks rejoin losslessly", table.concat(brokenWord), oneLongWord)

eq("wrap: empty text wraps to one empty line", #Util.wrap("", 19), 1)
eq("wrap: whitespace-only text wraps to one empty line", #Util.wrap("   ", 19), 1)

-- 12. BINARY SAFETY.
--
-- A save is a byte string: the engine's %q serialiser passes bytes >= 0x80
-- through raw, so save.lua need not be valid UTF-8. Every fixture in this
-- file used to be pure ASCII, which is exactly why the wire format could be
-- binary-unsafe for months and every test still passed -- while the first
-- real install got `400 Problems parsing JSON` from GitHub and uploaded
-- nothing. These bytes are the hostile ones: a lone 0xE9 (invalid UTF-8 on
-- its own), a valid multi-byte sequence, NUL, DEL, 0xFF, and the characters
-- JSON itself cares about.
local HOSTILE = "name=" .. string.char(233) .. " lone-high "
  .. string.char(194, 165) .. " yen " .. string.char(0) .. " nul "
  .. string.char(127) .. " del " .. string.char(255) .. " ff "
  .. string.char(34) .. "quote" .. string.char(34) .. " "
  .. string.char(92) .. " backslash " .. string.char(10) .. string.char(9)

activate(A)
local enc = A.Sync.encodeBlob(HOSTILE)
eq("blob encoding is ASCII-safe", enc:find("[\128-\255]"), nil)
check("blob encoding is self-describing", enc:sub(1, 4) == "b64:")
eq("blob round-trips byte-identically", A.Sync.decodeBlob(enc), HOSTILE)
eq("blob length survives", #A.Sync.decodeBlob(enc), #HOSTILE)

-- An object written before the prefix existed must still read back, or a
-- history entry from an older build becomes unrecoverable.
eq("legacy raw payloads still decode", A.Sync.decodeBlob("return {}"), "return {}")

-- And the whole way through: a save carrying those bytes must reach another
-- device unchanged, hash included.
local E = newDevice("Device E")
local F = newDevice("Device F")
play(E, { version = "red", player = { name = "RED" }, badges = 1, junk = HOSTILE,
          meta = { playthroughId = "PLAYBIN1", savedAt = 1000 } })
eq("E uploads a binary-laden save", sync(E), "idle")
eq("F adopts it", sync(F), "idle")

activate(E)
local eRec = E.Store.readSlot("red", E.saveData.activeSlot())
activate(F)
local fRec
for _, sl in ipairs(F.saveData.listSlots("red")) do
  local r = F.Store.readSlot("red", sl.id)
  if r and r.key == "red-PLAYBIN1" then fRec = r end
end
check("F received the binary save", fRec ~= nil)
if fRec and eRec then
  eq("bytes survived the round trip", fRec.bytes, eRec.bytes)
  eq("hash agrees on both devices", fRec.hash, eRec.hash)
  eq("the hostile bytes are intact", fRec.save.junk, HOSTILE)
end

-- Nothing binary may reach the wire, whatever the save contains.
for name, body in pairs(cloud.files) do
  if name:match("^red%-PLAYBIN1%.") and not name:match("%.json$") then
    eq("cloud object is ASCII: " .. name, body:find("[\128-\255]"), nil)
  end
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
