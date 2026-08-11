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
--    overwrites a save writes the outgoing bytes to cloud_saves/backups/
--    first, and the UI's Restore Previous Save reads exactly that folder.
--    A cloud round trip can be wrong; a lost playthrough cannot be undone.

local Util = CLOUD_SAVES_INCLUDE("src/util.lua")

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

local CONFIG_PATH = "cloud_saves/config.lua"
local BACKUP_DIR = "cloud_saves/backups"

-- Ten is a lot of history for a file that changes when the player walks into
-- a Poké Center, and it is small: ten copies of a Gen 1 save is under half a
-- megabyte.  The same number bounds the cloud-side history.
local KEEP_BACKUPS = 10

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
  f.createDirectory("cloud_saves")
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

function Store.forget()
  local cfg = Store.config()
  cfg.provider, cfg.cfg, cfg.keys = nil, nil, {}
  Store.saveConfig(cfg)
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
  for _, id in ipairs({ "red", "blue", "yellow" }) do
    if GameVersion.info and GameVersion.info(id) then out[#out + 1] = id end
  end
  if #out == 0 then out = { GameVersion.get and GameVersion.get() or "red" } end
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
  -- A pre-identity save has no id until the next in-game SAVE stamps one in;
  -- until then the slot names it, which is stable on this device.
  return version .. "-" .. tostring(slotId or "legacy")
end

--- Read the active save for a version straight off disk.
--- Returns nil when there is nothing saved yet (a brand new install), which
--- is a normal state, not an error.
function Store.readLocal(version)
  local f = fs()
  if not f then return nil end
  local path = SaveData.saveFilename(version)
  if not path or not f.getInfo(path) then return nil end
  local bytes = f.read(path)
  if type(bytes) ~= "string" or bytes == "" then return nil end
  local ok, save = pcall(SaveSerializer.decode, bytes)
  if not ok or type(save) ~= "table" then return nil end
  local slotId = SaveData.activeSlot(version)
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

--- Every local save, keyed by sync key.
function Store.readAllLocal()
  local out = {}
  for _, v in ipairs(Store.versions()) do
    local rec = Store.readLocal(v)
    if rec then out[rec.key] = rec end
  end
  return out
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

--- Copy bytes into the backup folder for a key.  Returns the filename.
function Store.backup(key, bytes, tag)
  local f = fs()
  if not f or type(bytes) ~= "string" or bytes == "" then return nil end
  local dir = backupDir(key)
  f.createDirectory(dir)
  local name = ("%s-%s-%s.sav"):format(Util.stamp(), Util.short(Util.hash(bytes)),
    tag or "local")
  if not f.write(dir .. "/" .. name, bytes) then return nil end

  -- Prune oldest first.  Names begin with a sortable UTC stamp, so plain
  -- lexicographic order is chronological order.
  local items = f.getDirectoryItems(dir)
  table.sort(items)
  for i = 1, #items - KEEP_BACKUPS do f.remove(dir .. "/" .. items[i]) end
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

--- Replace the active save for a version with `bytes`, backing up whatever
--- was there first.  `tag` labels the backup so Restore can say where the
--- displaced save came from.
function Store.apply(version, key, bytes, tag)
  local save, err = Store.validate(bytes, version)
  if not save then return false, err end

  local current = Store.readLocal(version)
  if current then
    Store.backup(key or current.key, current.bytes, tag or "replaced")
  end

  local slotId = SaveData.activeSlot(version)
  if not slotId then
    -- Nothing registered yet (a fresh install pulling a save down for the
    -- first time): make a slot and make it the one the title screen loads,
    -- or CONTINUE would find nothing after a successful download.
    slotId = SaveData.createSlot(version)
    if not slotId then
      return false, "could not make a save slot for " .. tostring(version)
    end
    SaveData.setActiveSlot(version, slotId)
  end

  local ok, werr = SaveData.writeSlot(version, slotId, save)
  if not ok then return false, tostring(werr or "could not write the save") end
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
