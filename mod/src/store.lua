-- Local side of sync: the mod's own config file, reading and replacing the
-- game's save slots, and the on-disk backups that make every cloud operation
-- undoable.
--
-- TWO RULES THIS MODULE EXISTS TO ENFORCE.
--
-- 1. The mod's config NEVER lives inside the game save.  mod.save:set would
--    put the access token in save.lua -- the very file this mod uploads --
--    which would publish the player's credentials to their own cloud and
--    make the token part of the synced state.  Config goes in its own file
--    under the LÖVE save directory instead, and is excluded from sync by
--    construction: sync only ever reads the game's save slots.
--
-- 2. Nothing is replaced without a local backup first.  Every path that
--    overwrites a save writes the outgoing bytes to savesync/backups/
--    first, and the UI's Restore Previous Save reads exactly that folder.
--    A cloud round trip can be wrong; a lost playthrough cannot be undone.

local Util = SAVESYNC_INCLUDE("src/util.lua")

-- These three private requires are why the manifest declares
-- `engine_internals`.  There is no mod-API surface for "read the active save
-- slot" or "replace it safely" -- mod.save only reaches a mod's own namespace
-- INSIDE the save -- and reimplementing the slot resolution, the legacy
-- migration and the .tmp/.bak write discipline would mean two copies of the
-- rules that decide where a player's progress lives.  Nothing here patches
-- engine code; it is read plus the engine's own writeSlot.
local SaveData = require("src.core.SaveData")
local SaveSerializer = require("src.core.SaveSerializer")
local GameVersion = require("src.core.GameVersion")

local Store = {}

local CONFIG_PATH = "savesync/config.lua"
local BACKUP_DIR = "savesync/backups"

-- Local retention is Util.thin, not a flat count -- see there for why.




-- ---------------------------------------------------------------- config

local cache

local function fs()
  return love and love.filesystem
end

local function blankConfig()
  return {
    version = 1,
    device = Util.randomId(8),
    deviceName = Store.guessDeviceName(),
    provider = nil,
    cfg = nil,
    auto = true,
    -- Ask to sync right after a save the player chose. On by default because
    -- the request was for the prompt; "Stop asking" on the prompt itself and
    -- this row both turn it off, so nobody is stuck with it.
    askOnSave = true,
    keys = {},
  }
end

function Store.guessDeviceName()
  local os_ = (love and love.system and love.system.getOS and love.system.getOS())
    or "this device"
  local names = { Windows = "Windows PC", ["OS X"] = "Mac", Linux = "Linux PC",
                  Android = "Android", iOS = "iPhone or iPad" }
  return names[os_] or os_
end

function Store.config()
  if cache then return cache end
  local f = fs()
  if f and f.getInfo(CONFIG_PATH) then
    local body = f.read(CONFIG_PATH)
    local ok, data = pcall(SaveSerializer.decode, body or "")
    if ok and type(data) == "table" and data.device then
      -- BACKFILL EVERY DEFAULT, not just `keys`.
      --
      -- A config written before a setting existed has no field for it, and a
      -- missing field is not the same as a false one. `askOnSave` displayed
      -- as `askOnSave ~= false` -- so nil read as ON -- while the code that
      -- fires the prompt tested it for truth, where nil is OFF. The row said
      -- ON and nothing ever asked. `auto` had the identical split across
      -- three call sites, quietly disabling upload-on-save and the boot check
      -- on every install that had been set up before those settings shipped.
      --
      -- Filling the gaps here means one answer to "what is this set to",
      -- rather than each reader guessing at nil in its own direction.
      local defaults = blankConfig()
      for k, v in pairs(defaults) do
        if data[k] == nil then data[k] = v end
      end
      data.keys = data.keys or {}
      cache = data
      return cache
    end
  end
  cache = blankConfig()
  return cache
end

function Store.saveConfig(cfg)
  cfg = cfg or cache
  if not cfg then return false end
  cache = cfg
  local f = fs()
  if not f then return false end
  f.createDirectory("savesync")
  local ok, encoded = pcall(SaveSerializer.encode, cfg)
  if not ok then return false, "could not encode config" end
  -- Same staged-write discipline the engine uses for save.lua: a power cut
  -- mid-write must not leave an unparseable config that strands the player's
  -- sign-in.
  f.write(CONFIG_PATH .. ".tmp", encoded)
  f.remove(CONFIG_PATH)
  local wrote = f.write(CONFIG_PATH, encoded)
  f.remove(CONFIG_PATH .. ".tmp")
  return wrote and true or false
end

-- Test seam: drop the in-process config cache so a suite can prove what
-- Store.config() does with what is actually ON DISK. The game reads the
-- config once per launch and has no reason to call this.
function Store.forgetCache()
  cache = nil
end

function Store.forget()
  local cfg = Store.config()
  cfg.provider, cfg.cfg, cfg.keys = nil, nil, {}
  Store.saveConfig(cfg)
end

--- Which slot a key was last written to, remembered across launches.
--- findSlotForKey answers this by reading every slot, but only while the
--- save on disk still computes to that key; the map is what makes apply()
--- idempotent even when it does not.
function Store.slotFor(key)
  local c = Store.config()
  c.slotMap = c.slotMap or {}
  return c.slotMap[key]
end

function Store.rememberSlot(key, slotId)
  if not key or not slotId then return end
  local c = Store.config()
  c.slotMap = c.slotMap or {}
  if c.slotMap[key] ~= slotId then
    c.slotMap[key] = slotId
    Store.saveConfig(c)
  end
end

function Store.keyState(key)
  local cfg = Store.config()
  cfg.keys[key] = cfg.keys[key] or {}
  return cfg.keys[key]
end

-- ----------------------------------------------------------- local saves

--- Every version the engine knows, so a player with Red and Blue saves
--- syncs both without being asked about it.
function Store.versions()
  local out = {}
  -- Read the engine's own registry rather than naming Red/Blue/Yellow here.
  -- Nothing in this mod is Gen 1 specific -- a save is bytes, a slot is a
  -- slot, and the sync key is "<version>-<playthroughId>" -- so an engine
  -- that adds Gold or Crystal to GameVersion.VERSIONS gets synced by this
  -- code unchanged. A hardcoded list would silently ignore them instead,
  -- which is the kind of failure nobody notices until a playthrough is
  -- stranded on one machine.
  local registry = GameVersion.VERSIONS
  if type(registry) == "table" then
    for id in pairs(registry) do
      if type(id) == "string" then out[#out + 1] = id end
    end
    -- Sorted so a cycle walks saves in the same order every time; pairs()
    -- order would make the report and the upload batch shuffle per run.
    table.sort(out)
  end
  if #out == 0 then out = { GameVersion.get and GameVersion.get() or "red" } end
  return out
end

--- Every slot on this device with the state sync has it in.
--- The screen shows this so a player can see at a glance which of their files
--- are safe and which are still waiting, rather than inferring it from a
--- single global "last synced" line that says nothing about slot three.
--- Slots holding a save the engine has not stamped yet.  These do not sync
--- (see keyFor); the next in-game SAVE stamps them and they join in.
function Store.unkeyedSlots()
  local out = {}
  for _, version in ipairs(Store.versions()) do
    for _, slot in ipairs(SaveData.listSlots(version) or {}) do
      local rec = slot.exists and Store.readSlot(version, slot.id)
      if rec and not rec.key then
        out[#out + 1] = {
          version = version, slotId = slot.id, status = "local only",
          name = rec.save and rec.save.player and rec.save.player.name or nil,
          badges = rec.summary and rec.summary.badges or nil,
        }
      end
    end
  end
  return out
end

function Store.slotOverview(conflicts)
  conflicts = conflicts or {}
  local out = {}
  for key, rec in pairs(Store.readAllLocal()) do
    local st = Store.keyState(key)
    local status
    if conflicts[key] then
      status = "conflict"
    elseif st.syncedHash == rec.hash then
      status = "synced"
    elseif st.syncedHash == nil then
      status = "new"
    else
      status = "waiting"
    end
    out[#out + 1] = {
      key = key,
      version = rec.version,
      slotId = rec.slotId,
      status = status,
      name = rec.save and rec.save.player and rec.save.player.name or nil,
      badges = rec.summary and rec.summary.badges or nil,
    }
  end
  for _, row in ipairs(Store.unkeyedSlots()) do out[#out + 1] = row end
  table.sort(out, function(a, b)
    if a.version ~= b.version then return a.version < b.version end
    return tostring(a.slotId) < tostring(b.slotId)
  end)
  return out
end

--- The sync key for a save: the version plus the engine's own playthrough
--- id.  The playthrough id is what makes cross-device pairing work at all --
--- it is stamped into the save itself, so the same playthrough carries the
--- same key onto a machine that has never seen it, whatever slot it lands in.
local function keyFor(version, save, slotId)
  local pid = save and type(save.meta) == "table" and save.meta.playthroughId
  if type(pid) == "string" and pid ~= "" then
    return version .. "-" .. pid:sub(1, 16)
  end
  -- NO ID, NO KEY. This used to fall back to "<version>-<slotId>", which is
  -- device-local by construction: downloaded onto a machine where that slot
  -- was taken, it matched nothing, so apply() made a new slot -- whose key
  -- then computed to the NEW slot id, so the next cycle matched nothing
  -- either and made another. One new save slot per sync, forever, until the
  -- player had fifty pages of them.
  --
  -- A save the engine has not stamped yet simply does not sync. The next
  -- in-game SAVE stamps it and it joins in, which is a wait measured in
  -- minutes rather than a mess measured in pages.
  return nil
end

-- Build a record from a slot path.  nil when the slot holds nothing, or
-- holds something that is not a save -- both normal states, not errors.
local function recordFor(version, slotId, path)
  local f = fs()
  if not f or not path or not f.getInfo(path) then return nil end
  local bytes = f.read(path)
  if type(bytes) ~= "string" or bytes == "" then return nil end
  local ok, save = pcall(SaveSerializer.decode, bytes)
  if not ok or type(save) ~= "table" then return nil end
  return {
    version = version,
    slotId = slotId,
    path = path,
    bytes = bytes,
    hash = Util.hash(bytes),
    key = keyFor(version, save, slotId),
    save = save,
    summary = select(2, pcall(SaveData.slotSummary, save)),
  }
end

--- Read one specific slot.
function Store.readSlot(version, slotId)
  if not slotId then return nil end
  return recordFor(version, slotId,
    "saves/" .. version .. "/" .. slotId .. ".lua")
end

--- Read the ACTIVE save for a version -- the one the title screen's CONTINUE
--- loads.  Still used by the UI, which talks about "this device's save".
function Store.readLocal(version)
  local f = fs()
  if not f then return nil end
  local path = SaveData.saveFilename(version)
  if not path then return nil end
  return recordFor(version, SaveData.activeSlot(version), path)
end

--- EVERY local save, keyed by sync key: every registered slot of every game
--- version, not just the active one.
---
--- A player with three Red files and a Yellow file has four playthroughs, and
--- syncing only whichever one they happened to have selected would leave the
--- other three stranded on one machine.  Slots are independent saves; they
--- are treated as independent saves.
function Store.readAllLocal()
  local out = {}
  for _, version in ipairs(Store.versions()) do
    local slots = SaveData.listSlots(version) or {}
    local seen = false
    for _, slot in ipairs(slots) do
      local rec = slot.exists and Store.readSlot(version, slot.id)
      if rec then
        seen = true
        -- A save the engine has not stamped with a playthrough id has no key,
        -- and nothing that has no key can sync: there is no name for it that
        -- means the same thing on a second device. It shows in Slots as
        -- "local only" rather than vanishing. See keyFor.
      end
      if rec and rec.key then
        -- Two slots claiming one playthrough id means a save was copied
        -- between slots.  Keep the first by slot order and leave the other
        -- alone rather than have them fight over the same cloud object.
        if not out[rec.key] then out[rec.key] = rec end
      end
    end
    -- A pre-slots install has a flat save.lua and no registry; listSlots
    -- migrates it, but on an engine build where it does not, this keeps the
    -- legacy save syncing instead of silently dropping it.
    if not seen then
      local rec = Store.readLocal(version)
      if rec and rec.key and not out[rec.key] then out[rec.key] = rec end
    end
  end
  return out
end

--- Which slot on this device holds the playthrough a cloud key names, if any.
--- This is what stops a download landing on the wrong file: without it, a
--- save pulled for playthrough X would be written into whichever slot
--- happened to be selected, destroying playthrough Y.
function Store.findSlotForKey(version, key)
  for _, slot in ipairs(SaveData.listSlots(version) or {}) do
    if slot.exists then
      local rec = Store.readSlot(version, slot.id)
      if rec and rec.key == key then return slot.id end
    end
  end
  return nil
end

--- Which engine version a cloud key belongs to.  Keys are "<version>-<id>",
--- and versions never contain a hyphen.
function Store.versionOfKey(key)
  return tostring(key):match("^([^%-]+)%-")
end

-- -------------------------------------------------------------- backups

local function backupDir(key)
  return BACKUP_DIR .. "/" .. tostring(key):gsub("[^%w%-_]", "_")
end

--- Copy bytes into the backup folder for a key.  Returns the filename, or nil
--- when there was nothing new to keep.
function Store.backup(key, bytes, tag)
  local f = fs()
  if not f or type(bytes) ~= "string" or bytes == "" then return nil end
  local dir = backupDir(key)
  f.createDirectory(dir)
  local hash = Util.hash(bytes)

  -- Never store the same bytes twice in a row.  Backups are capped, so a
  -- duplicate does not just waste space -- it pushes a genuinely different
  -- older version off the end of the list.
  local existing = f.getInfo(dir) and f.getDirectoryItems(dir) or {}
  table.sort(existing)
  local newest = existing[#existing]
  if newest and newest:find(Util.short(hash), 1, true) then return nil end

  local name = ("%s-%s-%s.sav"):format(Util.stamp(), Util.short(hash),
    tag or "local")
  if not f.write(dir .. "/" .. name, bytes) then return nil end

  -- Thinned, not capped. See Util.thin: the newest few, then one per hour,
  -- then one per day. A flat "keep ten" filled the list with ten copies of
  -- the last eight minutes and threw away yesterday.
  local items = f.getDirectoryItems(dir)
  local keep = Util.thin(items)
  for _, item in ipairs(items) do
    if not keep[item] then f.remove(dir .. "/" .. item) end
  end
  return name
end

--- Newest first: { name, when, size, tag } for the Restore screen.
function Store.listBackups(key)
  local f = fs()
  if not f then return {} end
  local dir = backupDir(key)
  if not f.getInfo(dir) then return {} end
  local items = f.getDirectoryItems(dir)
  table.sort(items, function(a, b) return a > b end)
  local out = {}
  for _, name in ipairs(items) do
    local info = f.getInfo(dir .. "/" .. name)
    local date, tag = name:match("^(%d+%-%d+)%-%x+%-(%a+)%.sav$")
    out[#out + 1] = {
      name = name,
      path = dir .. "/" .. name,
      size = info and info.size or 0,
      when = date and (date:sub(1, 4) .. "-" .. date:sub(5, 6) .. "-"
        .. date:sub(7, 8) .. " " .. date:sub(10, 11) .. ":" .. date:sub(12, 13))
        or name,
      tag = tag or "local",
    }
  end
  return out
end

function Store.readBackup(key, name)
  local f = fs()
  if not f then return nil end
  local path = backupDir(key) .. "/" .. name
  if not f.getInfo(path) then return nil end
  return f.read(path)
end

-- ---------------------------------------------------- replacing a save

--- Decode and sanity-check a blob before it is allowed anywhere near a save
--- slot.  A truncated download or a file someone hand-edited in the gist web
--- UI must be rejected here, not discovered by the title screen.
function Store.validate(bytes, version)
  if type(bytes) ~= "string" or bytes == "" then return nil, "empty save" end
  local ok, save = pcall(SaveSerializer.decode, bytes)
  if not ok or type(save) ~= "table" then return nil, "unreadable save file" end
  if version and save.version and save.version ~= version then
    return nil, "that save is for " .. tostring(save.version)
  end
  -- The engine's own loader rebuilds anything missing, so this only refuses
  -- files that are clearly not saves at all.
  if type(save.player) ~= "table" and type(save.party) ~= "table" then
    return nil, "that file is not a save"
  end
  return save
end

--- Write `bytes` into the slot that belongs to `key`, backing up whatever was
--- there first.  `tag` labels the backup so Restore can say where the
--- displaced save came from.
---
--- THE SLOT IS CHOSEN BY PLAYTHROUGH, NEVER BY WHAT IS SELECTED.  A download
--- for playthrough X must land in the slot holding playthrough X; writing it
--- into whichever slot happened to be active would destroy an unrelated
--- playthrough, which is the one thing this mod exists not to do.  A
--- playthrough this device has never seen gets a NEW slot -- and does not
--- steal the active selection from a save the player is in the middle of.
function Store.apply(version, key, bytes, tag)
  local save, err = Store.validate(bytes, version)
  if not save then return false, err end

  -- The remembered slot wins: it is the only source that survives the save's
  -- own key changing, which is exactly the case that ran away.
  local slotId = key and Store.slotFor(key) or nil
  if slotId and not SaveData.saveFilename then slotId = nil end
  if slotId then
    local exists = false
    for _, slot in ipairs(SaveData.listSlots(version) or {}) do
      if slot.id == slotId then exists = true end
    end
    if not exists then slotId = nil end
  end
  if not slotId then
    slotId = key and Store.findSlotForKey(version, key) or nil
  end
  local isNewSlot = false
  if not slotId then
    -- Fall back to the active slot only when it is EMPTY or already holds
    -- this same playthrough; otherwise take a fresh slot.
    local active = SaveData.activeSlot(version)
    local activeRec = active and Store.readSlot(version, active) or nil
    if active and (not activeRec or not key or activeRec.key == key) then
      slotId = active
    else
      slotId = SaveData.createSlot(version)
      isNewSlot = true
      if not slotId then
        return false, "could not make a save slot for " .. tostring(version)
      end
    end
  end

  local current = Store.readSlot(version, slotId)
  if current then
    Store.backup(key or current.key, current.bytes, tag or "replaced")
  end

  local ok, werr = SaveData.writeSlot(version, slotId, save)
  if not ok then return false, tostring(werr or "could not write the save") end
  -- Remember it BEFORE anything else can fail, so a crash here cannot leave
  -- the next cycle thinking this key has no home and making another slot.
  Store.rememberSlot(key, slotId)

  -- Point CONTINUE at the new file only when nothing was selected before --
  -- a fresh install adopting its first save. Otherwise the player's current
  -- selection is theirs to change, not ours.
  if isNewSlot and not SaveData.activeSlot(version) then
    SaveData.setActiveSlot(version, slotId)
  end
  return true
end

--- Restore one of the local backups over the live save (itself backed up
--- first, so Restore is never a one-way door either).
function Store.restoreBackup(version, key, name)
  local bytes = Store.readBackup(key, name)
  if not bytes then return false, "that backup is gone" end
  return Store.apply(version, key, bytes, "undo")
end

return Store
