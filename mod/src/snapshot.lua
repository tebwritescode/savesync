-- Snapshots: point-in-time copies of the live game state that never touch
-- the player's save file.
--
-- WHAT THESE ARE NOT.  Gen1Recomp is a native Lua recreation, not an
-- emulator -- there is no CPU, no RAM and no framebuffer, so an emulator-style
-- save state is not a thing that can exist here.  What the engine does offer
-- is `mod.checkpoints`: the full progress state captured as pure data, with a
-- transactional restore that verifies the result and rolls back in memory if
-- reconstruction fails.  That is what a snapshot is here.
--
-- WHY THEY BEAT AUTOSAVING THE SAVE FILE.  In Gen 1, soft-resetting to re-roll
-- a starter or a legendary works precisely because the game only writes
-- `save.lua` when told.  Writing it on a timer breaks that silently.  A
-- snapshot writes somewhere else entirely, so it can run on a timer, by
-- default, without touching how the game plays.  Reset all you like; the
-- snapshot is a parachute, not a save.
--
-- THE CEILING, STATED PLAINLY.  Checkpoint format 1 is settled-overworld
-- only: topmost, stationary on a tile, no transition, menu, script, queued
-- movement or partial animation.  You cannot snapshot mid-battle. This is
-- crash insurance, not save-anywhere.
--
-- Snapshots are IMMUTABLE and append-only, which is why syncing them needs
-- none of the conflict machinery saves do: two devices can only ever add
-- different snapshots, never disagree about one.

local Util = SAVESYNC_INCLUDE("src/util.lua")
local Store = SAVESYNC_INCLUDE("src/store.lua")

local SaveSerializer = require("src.core.SaveSerializer")

local Snapshot = {}

Snapshot.FORMAT = 1

-- Per playthrough. Ten covers "something went wrong a while ago" without
-- turning the folder into an archive; each is a few KB.
local KEEP = 10

local DIR = "savesync/snapshots"

local api    -- mod.checkpoints, bound at load

--- main.lua hands over the engine's checkpoint API.  Kept behind a bind
--- rather than reached through a global so this module stays testable.
function Snapshot.bind(mod)
  api = mod and mod.checkpoints or nil
end

--- False on an engine build predating the checkpoint API, in which case the
--- feature hides itself rather than erroring at the player.
function Snapshot.available()
  return api ~= nil and type(api.capture) == "function"
end

local function fs()
  return love and love.filesystem
end

local function dirFor(key)
  return DIR .. "/" .. tostring(key):gsub("[^%w%-_]", "_")
end

-- ------------------------------------------------------------- capability

--- The engine's own answer to "can a snapshot be taken right now", passed
--- through unchanged so the UI can show its message verbatim rather than
--- inventing a worse one.
function Snapshot.inspect(game)
  if not Snapshot.available() then
    return { canCapture = false, canRestore = false,
             message = "This engine build has no snapshot support." }
  end
  if not game then
    return { canCapture = false, canRestore = false,
             message = "Start a game first." }
  end
  local ok, cap = pcall(function() return api:inspect(game) end)
  if not ok or type(cap) ~= "table" then
    return { canCapture = false, canRestore = false,
             message = "Snapshots are unavailable right now." }
  end
  return cap
end

--- The sync key a snapshot belongs to -- the same key the save itself uses,
--- so a snapshot and the save it came from stay together everywhere.
function Snapshot.keyFor(checkpoint)
  local id = checkpoint and checkpoint.identity
  if type(id) ~= "table" then return nil end
  local version, pid = id.gameVersion, id.playthroughId
  if type(version) ~= "string" or type(pid) ~= "string" or pid == "" then
    return nil
  end
  return version .. "-" .. pid:sub(1, 16)
end

-- ---------------------------------------------------------------- capture

--- Take a snapshot.  Returns name, key on success; nil plus a player-facing
--- message otherwise (including the engine's own refusal text).
function Snapshot.take(game, tag)
  if not Snapshot.available() then return nil, "snapshots are not supported here" end
  local ok, checkpoint, _code, message = pcall(function()
    return api:capture(game)
  end)
  if not ok then return nil, "snapshot failed" end
  if not checkpoint then return nil, message or "cannot snapshot right now" end

  local key = Snapshot.keyFor(checkpoint)
  if not key then return nil, "this playthrough has no identity yet" end

  local record = {
    format = Snapshot.FORMAT,
    takenAt = Util.now(),
    tag = tag or "auto",
    device = Store.config().device,
    deviceName = Store.config().deviceName,
    checkpoint = checkpoint,
  }
  local encOk, encoded = pcall(SaveSerializer.encode, record)
  if not encOk then return nil, "snapshot could not be written" end

  local f = fs()
  if not f then return nil, "no filesystem" end
  local dir = dirFor(key)
  f.createDirectory(dir)
  -- The stamp sorts chronologically and the hash keeps two snapshots taken
  -- in the same second from colliding.
  local name = ("%s-%s.snap"):format(Util.stamp(),
    Util.short(Util.hash(encoded)))
  if not f.write(dir .. "/" .. name, encoded) then
    return nil, "snapshot could not be written"
  end
  Snapshot.prune(key)
  return name, key
end

function Snapshot.prune(key)
  local f = fs()
  if not f then return end
  local dir = dirFor(key)
  if not f.getInfo(dir) then return end
  local items = f.getDirectoryItems(dir)
  table.sort(items)
  for i = 1, #items - KEEP do f.remove(dir .. "/" .. items[i]) end
end

-- ------------------------------------------------------------------ read

--- Newest first.
function Snapshot.list(key)
  local f = fs()
  if not f then return {} end
  local dir = dirFor(key)
  if not f.getInfo(dir) then return {} end
  local items = f.getDirectoryItems(dir)
  table.sort(items, function(a, b) return a > b end)
  local out = {}
  for _, name in ipairs(items) do
    local date = name:match("^(%d+%-%d+)")
    out[#out + 1] = {
      name = name,
      when = date and (date:sub(5, 6) .. "/" .. date:sub(7, 8) .. " "
        .. date:sub(10, 11) .. ":" .. date:sub(12, 13)) or name,
    }
  end
  return out
end

function Snapshot.readRaw(key, name)
  local f = fs()
  if not f then return nil end
  local path = dirFor(key) .. "/" .. name
  if not f.getInfo(path) then return nil end
  return f.read(path)
end

function Snapshot.decode(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, record = pcall(SaveSerializer.decode, raw)
  if not ok or type(record) ~= "table" then return nil end
  if type(record.checkpoint) ~= "table" then return nil end
  return record
end

--- Write a snapshot that arrived from another device.  Snapshots are
--- immutable, so an existing name is already the same bytes and is left
--- alone rather than rewritten.
function Snapshot.writeRaw(key, name, raw)
  local f = fs()
  if not f or not Snapshot.decode(raw) then return false end
  local dir = dirFor(key)
  f.createDirectory(dir)
  local path = dir .. "/" .. name
  if f.getInfo(path) then return true end
  local ok = f.write(path, raw)
  if ok then Snapshot.prune(key) end
  return ok and true or false
end

--- Every local snapshot across every playthrough: { key -> { name -> raw } }.
--- Used by the sync cycle, which runs with no game in play, so it reads the
--- folder rather than asking the engine.
function Snapshot.allLocal()
  local f = fs()
  local out = {}
  if not f or not f.getInfo(DIR) then return out end
  for _, dir in ipairs(f.getDirectoryItems(DIR)) do
    local full = DIR .. "/" .. dir
    local info = f.getInfo(full)
    if info and info.type == "directory" then
      for _, name in ipairs(f.getDirectoryItems(full)) do
        if name:sub(-5) == ".snap" then
          -- The folder name is the sanitised key; recover the real one from
          -- the record so a key with unusual characters still round-trips.
          local raw = f.read(full .. "/" .. name)
          local rec = Snapshot.decode(raw)
          local key = rec and Snapshot.keyFor(rec.checkpoint)
          if key then
            out[key] = out[key] or {}
            out[key][name] = raw
          end
        end
      end
    end
  end
  return out
end

-- --------------------------------------------------------------- restore

--- Restore a snapshot over the live game.
---
--- A recovery snapshot is taken FIRST.  The engine rolls back in memory if
--- reconstruction fails, but the docs are explicit that a caller wanting
--- crash recovery must durably capture its own -- so this does, and it is
--- what makes restoring a snapshot itself undoable.
function Snapshot.restore(game, key, name)
  if not Snapshot.available() then return false, "snapshots are not supported here" end
  local record = Snapshot.decode(Snapshot.readRaw(key, name))
  if not record then return false, "that snapshot is unreadable" end

  Snapshot.take(game, "undo")

  local ok, done, _code, message = pcall(function()
    return api:restore(game, record.checkpoint)
  end)
  if not ok then return false, "restore failed" end
  if not done then return false, message or "restore failed" end
  return true
end

return Snapshot
