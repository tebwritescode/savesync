-- The sync engine.
--
-- One cycle, run after every in-game save and on a slow timer, does this:
--
--   1. read the cloud's manifests
--   2. for each save, compare three hashes: what is on disk, what is in the
--      cloud, and what this device last agreed with the cloud about
--   3. upload, download, do nothing -- or refuse and raise a conflict
--
-- THE THREE-HASH RULE is the whole safety story.  `syncedHash` is the last
-- state this device and the cloud were known to agree on.  If only the local
-- file moved away from it, this device is ahead: upload.  If only the cloud
-- did, the other device is ahead: download.  If BOTH moved, two devices
-- changed the same save independently and no automatic answer is correct --
-- so the engine stops, says so, and waits for the player.  There is no code
-- path where a newer file is overwritten because it happened to have an
-- older wall-clock timestamp, which is how naive sync loses playthroughs.
--
-- EVERY UPLOAD IS ALSO A HISTORY ENTRY.  A cycle writes `<key>.sav`,
-- `<key>.json` and `<key>.h<seq>.sav` in one batch, so the version a device
-- overwrites is already archived by the device that wrote it -- the loser of
-- a conflict is always recoverable from either side.
--
-- ONLY SAVES GO UP.  The upload set is built from Store.readAllLocal(),
-- which reads the engine's save slots and nothing else.  ROM data, the ROM
-- cache, assets and this mod's own config are not reachable from here.
--
-- SNAPSHOTS GET NONE OF THE ABOVE.  A snapshot (src/snapshot.lua) is
-- immutable once written -- taking one never edits an existing file, only
-- adds a new one -- so two devices can only ever ADD different snapshots,
-- never disagree about one.  There is nothing for the three-hash rule to
-- protect against, so the snapshot half of a cycle below is just "make both
-- sides hold the union of what exists, newest ten kept on each."  Cloud
-- names are "<key>.s<local-filename>", <local-filename> being exactly what
-- Snapshot.take() already wrote to disk -- no separate id to invent or keep
-- in step between the two.

local Op = SAVESYNC_INCLUDE("src/op.lua")
local Json = SAVESYNC_INCLUDE("src/json.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")
local Store = SAVESYNC_INCLUDE("src/store.lua")
local Snapshot = SAVESYNC_INCLUDE("src/snapshot.lua")
local Providers = SAVESYNC_INCLUDE("src/providers/init.lua")

local Sync = {}

-- How many past versions of each save the cloud keeps.  The data is tiny, so
-- this is bounded by tidiness rather than by cost.
local KEEP_HISTORY = 10

-- Same cap for snapshots, on both sides -- see the comment atop this file
-- for why they need no conflict handling to get there.
local SNAPSHOT_KEEP = 10

-- Debounce after an in-game save: the player may be about to save again
-- (Poké Center, then straight back out), and one upload for the pair is
-- kinder to everybody than two.
local UPLOAD_DELAY = 4

-- Idle re-check.  A second device that has been left running should notice a
-- save made elsewhere without the player pressing anything.
local IDLE_INTERVAL = 300

-- Offline retry backoff, capped.  A player on a plane should not have the
-- mod hammering a dead connection.
local RETRY_STEPS = { 20, 60, 180, 300 }

Sync.state = "off"           -- off | idle | working | conflict | error | offline
Sync.status = ""
Sync.lastSync = 0
Sync.conflicts = {}          -- key -> { local_, cloud }
Sync.deferred = nil          -- a download held back because a game is live

-- BOOT CHECK STATE, for the title screen's "is this save current?" gate.
--
-- "checking" until the first cycle after game.ready finishes, then "ok",
-- "offline" or "error". CONTINUE reads this: loading a save the cloud has
-- already moved past is not data loss (the three-hash rule turns it into a
-- conflict rather than an overwrite) but it costs the player every hour they
-- then play on the wrong file, and they deserve to be told before that
-- rather than after.
Sync.boot = "off"            -- off | checking | ok | offline | error
Sync.syncedSeq = 0           -- bumped when a sync the player ASKED for lands
Sync.bootNote = nil          -- what to tell the player, when it is not "ok"

local op                     -- the single in-flight op, if any
local dirtyAt                -- when an in-game save asked for an upload
local nextIdle = 0
local retryIndex = 0
local retryAt = 0

-- Set by main.lua.  A download must never land under a live session: the
-- running game holds the old save in memory and would write it straight back
-- out at the next SAVE, silently undoing the download.
Sync.canApplyDownload = function() return true end

-- ------------------------------------------------------- blob encoding

-- A SAVE IS BYTES, NOT TEXT, AND THE WIRE IS JSON.
--
-- The engine serialises saves with Lua's `%q`, which passes bytes >= 0x80
-- through raw -- so save.lua is a byte string that need not be valid UTF-8.
-- Putting those bytes straight into a JSON body is what broke the first real
-- install: GitHub answered `400 {"message":"Problems parsing JSON"}` and no
-- save ever uploaded.  The self-hosted server was worse -- Node's
-- toString('utf8') turns an invalid byte into U+FFFD, so it would have
-- CORRUPTED the save silently instead of refusing it.
--
-- So payloads are base64 on the wire, behind a self-describing prefix: it
-- needs no manifest flag, and an object written by an older build (raw) is
-- still readable, which matters because history entries outlive the code that
-- wrote them.  Manifests are excluded -- this mod generates them, they are
-- ASCII by construction, and leaving them plain keeps a gist readable by a
-- human who wants to see what happened.
local BLOB_PREFIX = "b64:"

local function encodeBlob(bytes)
  return BLOB_PREFIX .. Util.b64(bytes)
end

local function decodeBlob(text)
  if type(text) ~= "string" or text == "" then return nil end
  if text:sub(1, #BLOB_PREFIX) == BLOB_PREFIX then
    return Util.unb64(text:sub(#BLOB_PREFIX + 1))
  end
  return text                 -- legacy object, written before the prefix
end

-- Exposed for tests: the round trip is the whole safety property here.
Sync.encodeBlob, Sync.decodeBlob = encodeBlob, decodeBlob

-- ------------------------------------------------------------ names

--- A key that names a SLOT rather than a playthrough.
---
--- Builds up to 1.9.x keyed an unstamped save `<version>-<slotId>`, which
--- means a different save on every device. Those keys are still sitting in
--- players' clouds, and each one is a separate object -- so a device syncing
--- against such a cloud creates one local slot per stray key, every time,
--- which is how an install ends up with fifty pages of save slots even after
--- the key scheme itself was fixed.
---
--- They cannot be interpreted: nothing on this device can know which
--- playthrough `red-slot7` meant on the machine that wrote it. So they are
--- never applied, and Clean Up Cloud can remove them.
local function isLegacyKey(key)
  key = tostring(key or "")
  return key:match("^.+%-slot%d+$") ~= nil or key:match("^.+%-legacy$") ~= nil
end

local function savName(key) return key .. ".sav" end
local function jsonName(key) return key .. ".json" end
-- History entries carry the moment they were taken, because "version 3"
-- tells a player nothing about which one they want back. The sequence still
-- leads so the name sorts and prunes by age.
local function histName(key, seq)
  return ("%s.h%04d-%s.sav"):format(key, seq, Util.stamp())
end

-- Reads both shapes: with the stamp, and the older "<key>.h0003.sav" written
-- before it was added. History outlives the code that wrote it, so dropping
-- the old form would make a player's existing versions unrestorable.
local function parseHist(name)
  local key, seq, stamp = name:match("^(.+)%.h(%d+)%-([%d%-]+)%.sav$")
  if key then return key, tonumber(seq), stamp end
  key, seq = name:match("^(.+)%.h(%d+)%.sav$")
  return key, tonumber(seq), nil
end

-- Cloud object name for a snapshot: "<key>.s<local-name>".  <local-name> is
-- exactly the filename Snapshot.take() wrote to disk -- a stamp plus a short
-- content hash, see snapshot.lua -- and the "s" marks it apart from the
-- h0001-style save-history entries above so the two never collide.
local function snapCloudName(key, localName) return key .. ".s" .. localName end

-- The inverse.  Matched against the fixed shape Snapshot.take() produces
-- (an 8-digit date, a dash, a 6-digit time, a dash, an 8-hex-digit short
-- hash, ".snap") rather than split on the LAST ".s", because a playthrough
-- id is free to contain characters that would make a positional split
-- ambiguous.
local function parseSnapName(name)
  return name:match("^(.+)%.s(%d+%-%d+%-%x+%.snap)$")
end

-- ------------------------------------------------------------ config

function Sync.configured()
  local c = Store.config()
  return c.provider ~= nil and c.cfg ~= nil
end

function Sync.provider()
  local c = Store.config()
  return c.provider and Providers.get(c.provider) or nil
end

function Sync.describe()
  local p, c = Sync.provider(), Store.config()
  if not p then return "Not connected" end
  return p.describe(c.cfg)
end

-- Providers may refresh their own credentials mid-op (Dropbox does); persist
-- the moment they say so rather than at some later checkpoint that a crash
-- could skip.
local function persistProviderConfig()
  local c = Store.config()
  if c.cfg and c.cfg.dirty then
    c.cfg.dirty = nil
    Store.saveConfig(c)
  end
end

-- ------------------------------------------------------- the cycle

local function manifestFor(rec, seq, parent)
  local s = rec.summary or {}
  return {
    v = 1,
    key = rec.key,
    hash = rec.hash,
    seq = seq,
    parent = parent,
    device = Store.config().device,
    deviceName = Store.config().deviceName,
    savedAt = (type(rec.save.meta) == "table" and rec.save.meta.savedAt)
      or Util.now(),
    uploadedAt = Util.now(),
    -- purely so the conflict screen can say "RED, 3 badges, 4:12" instead of
    -- showing the player two hashes and asking them to choose
    player = rec.save.player and rec.save.player.name or nil,
    badges = s.badges,
    time = s.timeText,
    dex = s.dexCount,
  }
end

--- Build the batch that uploads one save, including its history entry and
--- the prune of anything past KEEP_HISTORY.
local function uploadFiles(rec, seq, parent, existingNames)
  local files = {}
  files[savName(rec.key)] = encodeBlob(rec.bytes)
  files[jsonName(rec.key)] = Json.encode(manifestFor(rec, seq, parent))
  files[histName(rec.key, seq)] = encodeBlob(rec.bytes)

  -- Prune by the name that is actually there. Rebuilding a name from the
  -- sequence would miss every entry written in the other shape, and the
  -- history would grow forever without anyone noticing.
  local existing = {}
  for name in pairs(existingNames or {}) do
    local k, s = parseHist(name)
    if k == rec.key and s then existing[#existing + 1] = { seq = s, name = name } end
  end
  table.sort(existing, function(a, b) return a.seq > b.seq end)
  for i = KEEP_HISTORY, #existing do
    files[existing[i].name] = false
  end
  return files
end

--- THE DECISION TABLE, as a pure function of three hashes.
---
--- `localHash` is what is on disk, `cloudHash` what the cloud says it has,
--- and `agreed` the last state this device and the cloud were known to share
--- (nil when this device has never synced this save).  Kept separate from the
--- cycle so it can be tested exhaustively -- it is the one piece of logic
--- here that can lose a playthrough if it is wrong.
function Sync.decide(localHash, cloudHash, agreed)
  if localHash and not cloudHash then return "upload" end
  if cloudHash and not localHash then return "download" end
  if not localHash and not cloudHash then return "nothing" end
  if localHash == cloudHash then return "insync" end
  local localMoved = localHash ~= agreed
  local cloudMoved = cloudHash ~= agreed
  if localMoved and cloudMoved then return "conflict" end
  if localMoved then return "upload" end
  return "download"
end

--- One full sync pass.  Returns a small report the UI turns into a status
--- line; failures come back as op errors with a player-facing message.
function Sync.cycle(opts)
  opts = opts or {}
  local provider = Sync.provider()
  local conf = Store.config()
  if not provider then return Op.failed("SaveSync is not set up yet") end

  return Op.new(function(ctx)
    local names = ctx:await(provider.list(conf.cfg))
    persistProviderConfig()

    -- Which saves exist on either side.  A cloud key with no local file is a
    -- save from another device this one has never seen -- the whole point.
    local locals = Store.readAllLocal()
    local keys = {}
    for key in pairs(locals) do keys[key] = true end
    for name in pairs(names) do
      local k = name:match("^(.+)%.json$")
      -- A slot-shaped key is skipped rather than adopted: adopting one is
      -- what creates a stray local slot, and it would create another on the
      -- next cycle and the one after that.
      if k and not isLegacyKey(k) then keys[k] = true end
    end

    -- Read every manifest in one call; providers that can answer in a single
    -- request (gists, the self-hosted server) do.
    local wanted = {}
    for key in pairs(keys) do
      if names[jsonName(key)] then wanted[#wanted + 1] = jsonName(key) end
    end
    local manifests = {}
    if #wanted > 0 then
      local blobs = ctx:await(provider.read(conf.cfg, wanted))
      persistProviderConfig()
      for key in pairs(keys) do
        local raw = blobs[jsonName(key)]
        if raw then manifests[key] = Json.decode(raw) end
      end
    end

    local report = { uploaded = 0, downloaded = 0, conflicts = 0, deferred = 0 }
    local uploads = {}          -- name -> content, merged into one write
    local downloads = {}        -- key -> cloud manifest

    for key in pairs(keys) do
      local rec = locals[key]
      local cloud = manifests[key]
      local state = Store.keyState(key)
      local verdict = Sync.decide(rec and rec.hash, cloud and cloud.hash,
        state.syncedHash)

      if verdict == "upload" then
        local seq = (cloud and tonumber(cloud.seq) or 0) + 1
        for n, c in pairs(uploadFiles(rec, seq, cloud and cloud.hash, names)) do
          uploads[n] = c
        end
        -- Keep a local copy of everything published, not only of saves that
        -- get displaced.  Otherwise a player who only ever uses one device
        -- has an empty Restore Previous Save list -- there is nothing to
        -- overwrite them, so nothing ever gets backed up -- and rolling back
        -- their own mistake would mean going to the cloud for it.
        -- Store.backup ignores a repeat of the newest bytes, so this does
        -- not churn through the ten slots on repeated syncs.
        Store.backup(key, rec.bytes, "sent")
        state.pendingSeq, state.pendingHash = seq, rec.hash
        report.uploaded = report.uploaded + 1

      elseif verdict == "download" then
        downloads[key] = cloud
        report.downloaded = report.downloaded + 1

      elseif verdict == "conflict" then
        -- Two devices, one save, both changed.  Stop and ask.
        Sync.conflicts[key] = { key = key, localRec = rec, cloud = cloud }
        state.conflict = true
        report.conflicts = report.conflicts + 1

      elseif verdict == "insync" then
        state.syncedHash, state.syncedSeq = cloud.hash, cloud.seq
        state.conflict = nil
        Sync.conflicts[key] = nil
      end
    end

    -- ---- snapshots: no decision table, just "union, newest ten kept".  See
    -- the comment at the top of this file for why that is enough.  Uploads
    -- and deletes are merged into the SAME `uploads` batch the save logic
    -- above already builds, so a provider that can do a whole cycle in one
    -- request still only sends one; downloads are read separately below
    -- because they need their own bytes back, not a write confirmation.
    local localSnaps = Snapshot.allLocal()
    local cloudSnaps = {}                 -- key -> { local-name -> cloud-name }
    for cloudName in pairs(names) do
      local skey, sname = parseSnapName(cloudName)
      if skey then
        cloudSnaps[skey] = cloudSnaps[skey] or {}
        cloudSnaps[skey][sname] = cloudName
      end
    end
    local snapKeys = {}
    for key in pairs(localSnaps) do snapKeys[key] = true end
    for key in pairs(cloudSnaps) do snapKeys[key] = true end

    local snapDownloads = {}   -- { key, name, cloudName }
    for key in pairs(snapKeys) do
      local local_ = localSnaps[key] or {}
      local cloud_ = cloudSnaps[key] or {}
      -- Newest ten across BOTH sides, not just one -- a device that has been
      -- offline a while must not have its own cloud copy deleted out from
      -- under it just because THIS device already pruned its local one, and
      -- the cloud must not keep a name every device has independently moved
      -- past.
      local union, seen = {}, {}
      for n in pairs(local_) do seen[n] = true union[#union + 1] = n end
      for n in pairs(cloud_) do
        if not seen[n] then seen[n] = true union[#union + 1] = n end
      end
      table.sort(union)   -- the stamp sorts lexicographically = chronologically
      local keep = {}
      for i = math.max(1, #union - SNAPSHOT_KEEP + 1), #union do
        keep[union[i]] = true
      end
      for _, sname in ipairs(union) do
        local hasLocal, hasCloud = local_[sname] ~= nil, cloud_[sname] ~= nil
        if keep[sname] then
          if hasLocal and not hasCloud then
            uploads[snapCloudName(key, sname)] = encodeBlob(local_[sname])
            report.snapshotsUploaded = (report.snapshotsUploaded or 0) + 1
          elseif hasCloud and not hasLocal then
            snapDownloads[#snapDownloads + 1] =
              { key = key, name = sname, cloudName = cloud_[sname] }
          end
        elseif hasCloud then
          -- Fell out of the newest ten: prune the cloud copy.  The local
          -- side needs no matching delete here -- Snapshot.prune already
          -- caps the disk at ten and runs on every capture and download, so
          -- a name this stale is already gone from there or on its way out.
          uploads[snapCloudName(key, sname)] = false
        end
      end
    end

    if #snapDownloads > 0 then
      local wantSnap = {}
      for _, d in ipairs(snapDownloads) do wantSnap[#wantSnap + 1] = d.cloudName end
      local blobs = ctx:await(provider.read(conf.cfg, wantSnap))
      persistProviderConfig()
      for _, d in ipairs(snapDownloads) do
        local raw = decodeBlob(blobs[d.cloudName])
        if type(raw) == "string" and raw ~= ""
            and Snapshot.writeRaw(d.key, d.name, raw) then
          report.snapshotsDownloaded = (report.snapshotsDownloaded or 0) + 1
        end
      end
    end

    -- ---- downloads first: a device that is behind should catch up before
    -- it publishes anything, so a half-finished cycle never makes it the
    -- authority on a save it has not seen.
    if next(downloads) then
      if not Sync.canApplyDownload() then
        report.deferred = report.downloaded
        report.downloaded = 0
        Sync.deferred = true
        downloads = {}
      else
        local wantSav = {}
        for key in pairs(downloads) do wantSav[#wantSav + 1] = savName(key) end
        local blobs = ctx:await(provider.read(conf.cfg, wantSav))
        persistProviderConfig()
        for key, cloud in pairs(downloads) do
          local bytes = decodeBlob(blobs[savName(key)])
          local version = Store.versionOfKey(key)
          if type(bytes) == "string" and bytes ~= "" then
            if Util.hash(bytes) ~= cloud.hash then
              -- The manifest and the blob disagree: a partial write
              -- somewhere. Refuse rather than write a torn save to disk.
              ctx:fail("the cloud copy of " .. key .. " looks damaged")
            end
            local ok, err = Store.apply(version, key, bytes, "cloud")
            if not ok then ctx:fail(err) end
            local state = Store.keyState(key)
            state.syncedHash, state.syncedSeq = cloud.hash, cloud.seq
            state.conflict = nil
            Sync.conflicts[key] = nil
          end
        end
        Sync.deferred = nil
      end
    end

    -- ---- then uploads, in one batch
    if next(uploads) then
      ctx:await(provider.write(conf.cfg, uploads))
      persistProviderConfig()
      for key in pairs(keys) do
        local state = Store.keyState(key)
        if state.pendingHash then
          state.syncedHash, state.syncedSeq = state.pendingHash, state.pendingSeq
          state.pendingHash, state.pendingSeq = nil, nil
          state.conflict = nil
          Sync.conflicts[key] = nil
        end
      end
    end

    local c = Store.config()
    c.lastSync = Util.now()
    Store.saveConfig(c)
    return report
  end)
end

-- --------------------------------------------------- conflict resolution

--- Keep this device's version: publish it over the cloud head.  Nothing is
--- lost -- the cloud's version is already in cloud history, written there by
--- the device that uploaded it.
--- How many stray legacy objects the cloud is carrying.
--- Counts, does not touch anything, so the UI can offer the cleanup only
--- when there is something to clean and can say how much.
function Sync.countLegacy()
  local provider, conf = Sync.provider(), Store.config()
  if not provider then return Op.failed("not connected") end
  return Op.new(function(ctx)
    local names = ctx:await(provider.list(conf.cfg))
    persistProviderConfig()
    local seen, n = {}, 0
    for name in pairs(names) do
      local k = name:match("^(.+)%.json$") or name:match("^(.+)%.sav$")
        or name:match("^(.+)%.h%d+.*%.sav$")
      if k and isLegacyKey(k) and not seen[k] then seen[k] = true n = n + 1 end
    end
    return n
  end)
end

--- Delete every stray legacy object from the cloud.
---
--- WHY THIS IS SAFE TO DELETE. A `<version>-slotN` key names a slot on
--- whichever device wrote it, so it identifies nothing here and nothing on
--- any other device either -- there is no machine on which it can be
--- restored to the right playthrough. It was written by a bug, and while it
--- stays there every device that syncs grows another local save slot from it.
---
--- WHAT IS NOT TOUCHED. Every properly keyed save, its manifest and its whole
--- history stay exactly as they are; only slot-shaped keys go. The local
--- saves those objects were copied from are untouched by definition -- this
--- writes nothing to disk.
function Sync.cleanCloud()
  local provider, conf = Sync.provider(), Store.config()
  if not provider then return Op.failed("not connected") end
  return Op.new(function(ctx)
    local names = ctx:await(provider.list(conf.cfg))
    persistProviderConfig()

    local doomed, count = {}, 0
    for name in pairs(names) do
      -- Match on the OBJECT NAME, so a key's manifest, its save and every
      -- history entry go together rather than leaving orphans behind.
      local k = name:match("^(.+)%.json$") or name:match("^(.+)%.sav$")
      if k then
        k = k:gsub("%.h%d+.*$", "")
        if isLegacyKey(k) then
          doomed[name] = false     -- `false` is this API's delete
          count = count + 1
        end
      end
    end
    if count == 0 then return 0 end

    ctx:await(provider.write(conf.cfg, doomed))
    persistProviderConfig()

    -- Forget any local bookkeeping that pointed at them, so nothing tries to
    -- reconcile a key that no longer exists anywhere.
    local c = Store.config()
    for key in pairs(c.keys or {}) do
      if isLegacyKey(key) then c.keys[key] = nil end
    end
    for key in pairs(c.slotMap or {}) do
      if isLegacyKey(key) then c.slotMap[key] = nil end
    end
    Store.saveConfig(c)
    return count
  end)
end

function Sync.resolveKeepLocal(key)
  local con = Sync.conflicts[key]
  local provider, conf = Sync.provider(), Store.config()
  if not con or not provider then return Op.failed("nothing to resolve") end
  return Op.new(function(ctx)
    local names = ctx:await(provider.list(conf.cfg))
    persistProviderConfig()
    local rec = Store.readLocal(Store.versionOfKey(key)) or con.localRec
    local seq = (tonumber(con.cloud.seq) or 0) + 1
    ctx:await(provider.write(conf.cfg,
      uploadFiles(rec, seq, con.cloud.hash, names)))
    persistProviderConfig()
    local state = Store.keyState(key)
    state.syncedHash, state.syncedSeq, state.conflict = rec.hash, seq, nil
    Sync.conflicts[key] = nil
    Store.saveConfig(Store.config())
    return true
  end)
end

--- Take the cloud's version.  The displaced local save is written to
--- savesync/backups first by Store.apply, so Restore Previous Save can
--- put it back.
function Sync.resolveUseCloud(key)
  local con = Sync.conflicts[key]
  local provider, conf = Sync.provider(), Store.config()
  if not con or not provider then return Op.failed("nothing to resolve") end
  return Op.new(function(ctx)
    local blobs = ctx:await(provider.read(conf.cfg, { savName(key) }))
    persistProviderConfig()
    local bytes = decodeBlob(blobs[savName(key)])
    if type(bytes) ~= "string" or bytes == "" then
      return ctx:fail("the cloud copy has gone missing")
    end
    if Util.hash(bytes) ~= con.cloud.hash then
      return ctx:fail("the cloud copy looks damaged")
    end
    local ok, err = Store.apply(Store.versionOfKey(key), key, bytes, "cloud")
    if not ok then return ctx:fail(err) end
    local state = Store.keyState(key)
    state.syncedHash, state.syncedSeq, state.conflict =
      con.cloud.hash, con.cloud.seq, nil
    Sync.conflicts[key] = nil
    Store.saveConfig(Store.config())
    return true
  end)
end

-- ------------------------------------------------------- cloud history

--- List the versions of a save the cloud is holding, newest first.
function Sync.history(key)
  local provider, conf = Sync.provider(), Store.config()
  if not provider then return Op.failed("SaveSync is not set up yet") end
  return Op.new(function(ctx)
    local names = ctx:await(provider.list(conf.cfg))
    persistProviderConfig()
    local out = {}
    for name, size in pairs(names) do
      local k, seq, stamp = parseHist(name)
      if k == key then
        out[#out + 1] = { name = name, seq = seq, size = size, stamp = stamp }
      end
    end
    table.sort(out, function(a, b) return a.seq > b.seq end)
    return out
  end)
end

--- Pull one history entry down over the live save (backing the live one up).
function Sync.restoreHistory(key, name)
  local provider, conf = Sync.provider(), Store.config()
  if not provider then return Op.failed("SaveSync is not set up yet") end
  return Op.new(function(ctx)
    local blobs = ctx:await(provider.read(conf.cfg, { name }))
    persistProviderConfig()
    local bytes = decodeBlob(blobs[name])
    if type(bytes) ~= "string" or bytes == "" then
      return ctx:fail("that version is gone")
    end
    local ok, err = Store.apply(Store.versionOfKey(key), key, bytes, "undo")
    if not ok then return ctx:fail(err) end
    -- The restored bytes are now local-only; clearing syncedHash makes the
    -- next cycle treat this device as ahead and publish them, which is what
    -- the player asked for by restoring.
    local state = Store.keyState(key)
    state.syncedHash = nil
    Store.saveConfig(Store.config())
    return true
  end)
end

-- ---------------------------------------------------------- scheduling

local doneMessage           -- what to say when the current op succeeds

local function begin(newOp, working, done)
  op = newOp
  doneMessage = done
  Sync.state = "working"
  Sync.status = working or "Syncing..."
end

--- Ask for a sync.  `now` skips the debounce (the Sync Now button).
--- `announce` marks a sync the PLAYER asked for, by name, and is what earns
--- a confirmation when it lands. A background cycle finishing is not news;
--- pressing Sync Now and being told nothing is.
function Sync.request(now, isBoot, announce)
  if not Sync.configured() then return end
  if isBoot then
    Sync.boot = "checking"
    Sync.bootNote = nil
  end
  if announce then Sync.announceNext = true end
  if now then
    dirtyAt = 0
    retryAt = 0
    if not op then begin(Sync.cycle(), "Syncing...") end
  else
    dirtyAt = os.time()
  end
end

--- The in-game save just happened.  Debounced, because saves come in pairs.
function Sync.markSaved()
  if not Sync.configured() then return end
  dirtyAt = os.time()
end

local function isOffline(err)
  err = tostring(err or ""):lower()
  return err:find("could not resolve", 1, true)
    or err:find("no connection", 1, true)
    or err:find("connection", 1, true)
    or err:find("timed out", 1, true)
    or err:find("could not reach", 1, true)
    or err:find("no response", 1, true)
    or err:find("network", 1, true)
end

--- Pump.  Called once a frame from main.lua; does nothing at all when the
--- mod is not set up, which is the state most installs are in.
function Sync.update()
  if not Sync.configured() then
    Sync.state = "off"
    return
  end

  if op then
    local st, value = op:poll()
    if st == "pending" then return end
    op = nil
    if st == "ok" then
      retryIndex, retryAt = 0, 0
      -- Any successful cycle answers the boot question, not just the first:
      -- a player who sits on the title screen while the connection returns
      -- should stop being warned.
      if Sync.boot ~= "ok" then
        Sync.boot = "ok"
        Sync.bootNote = nil
      end
      Sync.lastSync = Store.config().lastSync or Util.now()
      if doneMessage then
        -- a foreground action (resolve, restore) says its own thing, then
        -- asks for a normal cycle so the two sides line up again
        Sync.state, Sync.status = "idle", doneMessage
        doneMessage = nil
        dirtyAt = os.time() - UPLOAD_DELAY
        return
      end
      if next(Sync.conflicts) then
        Sync.state = "conflict"
        Sync.status = "Two devices changed the same save"
      elseif Sync.deferred then
        Sync.state = "idle"
        Sync.status = "Newer save in the cloud -- return to the title screen"
      else
        Sync.state = "idle"
        local r = type(value) == "table" and value or {}
        if (r.uploaded or 0) > 0 then Sync.status = "Save uploaded"
        elseif (r.downloaded or 0) > 0 then Sync.status = "Save downloaded"
        else Sync.status = "Up to date" end
      end
      -- A COUNTER, NOT A FLAG.
      --
      -- Two surfaces confirm a sync: the HUD corner flash (in-world) and the
      -- SaveSync screen's message line (when that screen is what the player
      -- is looking at). A flag is CONSUMED by whichever reads it first, so
      -- whoever lost the race showed nothing -- and pressing Sync Now from
      -- the menu, where the screen covers the HUD, could never show anything
      -- at all. A counter lets each surface compare against its own last
      -- seen value and neither takes it from the other.
      if Sync.announceNext then
        Sync.announceNext = nil
        Sync.syncedSeq = (Sync.syncedSeq or 0) + 1
      end
      nextIdle = os.time() + IDLE_INTERVAL
    else
      if isOffline(value) then
        Sync.state = "offline"
        Sync.status = "Offline -- will retry"
        if Sync.boot == "checking" then
          Sync.boot = "offline"
          Sync.bootNote = "No connection, so this save could not be checked."
        end
      else
        Sync.state = "error"
        Sync.status = tostring(value)
        if Sync.boot == "checking" then
          Sync.boot = "error"
          Sync.bootNote = tostring(value)
        end
      end
      -- The request the player made is over; it failed, and the screen
      -- says so. Leaving this armed would hand the confirmation to whatever
      -- background cycle happened to succeed next.
      Sync.announceNext = nil
      retryIndex = math.min(retryIndex + 1, #RETRY_STEPS)
      retryAt = os.time() + RETRY_STEPS[retryIndex]
    end
    return
  end

  if Sync.state == "conflict" and next(Sync.conflicts) then return end

  local now = os.time()
  if retryAt > 0 then
    if now >= retryAt then
      retryAt = 0
      begin(Sync.cycle(), "Retrying...")
    end
    return
  end
  if dirtyAt and now - dirtyAt >= UPLOAD_DELAY then
    dirtyAt = nil
    begin(Sync.cycle(), "Saving to the cloud...")
    return
  end
  if not dirtyAt and now >= nextIdle then
    nextIdle = now + IDLE_INTERVAL
    begin(Sync.cycle(), "Checking...")
  end
end

--- Start an arbitrary provider/sync op as the foreground one (used by the UI
--- for conflict resolution and restores, which must not race a cycle).
function Sync.runForeground(newOp, label, done)
  if op then op:cancel() end
  begin(newOp, label, done)
end

function Sync.busy()
  return op ~= nil
end

--- Wipe local sync bookkeeping so the next cycle re-decides from scratch.
--- Used after a restore, and after connecting a new provider.
function Sync.resetBookkeeping()
  local c = Store.config()
  c.keys = {}
  Store.saveConfig(c)
  Sync.conflicts = {}
end

return Sync
