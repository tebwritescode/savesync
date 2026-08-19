-- The sync engine: five cloud slots on the official server, bindings from
-- local playthroughs to slots, and the rule that makes the whole design
-- trustworthy: NOTHING REPLACES A SAVE WITHOUT ASKING.
--
-- The server is the source of truth for bytes and a middleman for nothing
-- else. What flows without a question is exactly one thing: new progress
-- moving up (this device saved, the slot is where this device left it).
-- Everything else -- adopting a server copy, replacing a diverged one,
-- rebinding a slot to a different adventure -- is a question the player
-- answers, here or on the SaveSync screen.
--
-- Per key (`<version>-<playthroughId>`, the identity stamped inside the
-- save) the config remembers { slot, rev, hash }: which cloud slot it
-- syncs with, the server revision this device last agreed with, and the
-- bytes-hash of that agreement. That triple is the three-way compare:
--
--   local == last, server == last     nothing to do
--   local ~= last, server == last     upload, silently (fast-forward)
--   local == last, server ~= last     server has news -> ASK (gate/screen)
--   local ~= last, server ~= last     both moved      -> ASK, show both
--
-- The server enforces the same rule independently via baseRev, so even a
-- buggy or hostile client cannot clobber newer server bytes unasked.

local Store = SAVESYNC_INCLUDE("src/store.lua")
local Link = SAVESYNC_INCLUDE("src/serverlink.lua")
local Crypto = SAVESYNC_INCLUDE("src/crypto.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")

local Sync = {}

Sync.state = "off"        -- off | idle | working | question | error
Sync.status = nil         -- one line for the HUD/screen
Sync.boot = "off"         -- off | checking | ok | behind | offline | error
Sync.bootNews = nil       -- [key] = slot, when boot found server news
Sync.syncedSeq = 0        -- bumps on every landed sync a player asked for
Sync.question = nil       -- the active question, nil when none (see ask())
Sync.deferred = false     -- a chosen download waiting for the title screen
Sync.link = nil           -- the server session (serverlink.lua)

-- Seconds between the save landing on disk and the upload starting; a
-- second SAVE inside the window restarts it, so save-scumming does not
-- machine-gun the server.
local UPLOAD_DELAY = 3

local dirtyAt = nil
local pendingDownload = nil   -- { slot, key, bytes, meta } chosen, deferred

local function now()
  return (love and love.timer and love.timer.getTime) and love.timer.getTime() or os.clock()
end

local function hashOf(bytes)
  return Crypto.toHex(Crypto.sha256(bytes))
end

-- --------------------------------------------------------------- config

function Sync.configured()
  local c = Store.config()
  return type(c.account) == "table" and c.account.name ~= nil
end

function Sync.accountName()
  local c = Store.config()
  return c.account and c.account.name or nil
end

--- The binding record for a key, or nil. { slot, rev, hash }.
local function bindingOf(key)
  local c = Store.config()
  c.bindings = c.bindings or {}
  return c.bindings[key]
end

local function setBinding(key, record)
  local c = Store.config()
  c.bindings = c.bindings or {}
  c.bindings[key] = record
  Store.saveConfig(c)
end

--- Which key is bound to a slot, if any.
function Sync.keyForSlot(slot)
  local c = Store.config()
  for key, b in pairs(c.bindings or {}) do
    if b.slot == slot then return key end
  end
  return nil
end

function Sync.bindingFor(key)
  return bindingOf(key)
end

--- Bind a playthrough to a cloud slot (the player picked it on the slots
--- screen). The first upload establishes rev/hash.
function Sync.bind(key, slot)
  -- one slot serves one key; unbind whatever else pointed there
  local c = Store.config()
  c.bindings = c.bindings or {}
  for k, b in pairs(c.bindings) do
    if b.slot == slot and k ~= key then c.bindings[k] = nil end
  end
  c.bindings[key] = c.bindings[key] or {}
  c.bindings[key].slot = slot
  Store.saveConfig(c)
end

function Sync.unbind(key)
  setBinding(key, nil)
end

-- --------------------------------------------------------------- assess

--- The pure decision. Feed it the three hashes; get what may happen.
--- "ask_download" and "ask_both" are QUESTIONS -- nothing acts on them
--- without the player. This is the safety-critical function; its tests
--- break loudly if the rule drifts.
function Sync.assess(localHash, serverHash, lastHash)
  if localHash == serverHash then return "match" end
  local localMoved = localHash ~= lastHash
  local serverMoved = serverHash ~= lastHash
  if localMoved and not serverMoved then return "upload" end
  if serverMoved and not localMoved then return "ask_download" end
  return "ask_both"
end

-- --------------------------------------------------------------- session

local host, port, pin, modVersion

function Sync.init(opts)
  host, port, pin = opts.host, opts.port, opts.pin
  modVersion = opts.version
end

local function newLink()
  Sync.link = Link.new({
    host = host, port = port, pin = pin, version = modVersion,
    onEvent = function(kind, data)
      if kind == "credentials" then
        local c = Store.config()
        c.account = { name = data.name, verifier = data.verifier }
        Store.saveConfig(c)
      elseif kind == "recovery_code" then
        -- kept re-readable from the Account screen, like Gen1MMO does.
        -- The config file lives in the mod's private storage, never inside
        -- any save file this mod uploads or backs up.
        local c = Store.config()
        c.recoveryCode = data
        Store.saveConfig(c)
      end
    end,
  })
  return Sync.link
end

--- A ready link, or nil plus why not. Starts a stored-credential session
--- when none is up.
local function readyLink()
  if Sync.link and Sync.link:ready() then return Sync.link end
  local c = Store.config()
  if not (c.account and c.account.name and c.account.verifier) then
    return nil, "not signed in"
  end
  if not Sync.link or Sync.link.state == "offline" or Sync.link.state == "error" then
    newLink():loginStored(c.account.name, c.account.verifier)
  end
  return nil, "connecting"
end

--- Auth entry points for the UI. Passwords pass through to the link and
--- are burned to verifiers there; nothing here retains them.
function Sync.register(name, password) newLink():register(name, password) end
function Sync.login(name, password) newLink():login(name, password) end
function Sync.recover(name, code, newPassword) newLink():recover(name, code, newPassword) end

function Sync.logout()
  if Sync.link then Sync.link:disconnect() end
  local c = Store.config()
  c.account = nil
  c.bindings = {}
  -- the recovery code stays readable: it is the player's, not the session's
  Store.saveConfig(c)
  Sync.state, Sync.status, Sync.boot = "off", nil, "off"
end

-- --------------------------------------------------------------- questions

--- One question at a time. { kind, key, slot, have, localLabel, answer }.
--- kinds: "server_newer" (adopt server copy?), "both_moved" (pick a side),
--- "slot_conflict" (slot holds a different adventure). The UI calls
--- Sync.answer(choice); choices per kind are documented on the screen.
local function ask(question)
  if Sync.question then return end -- one at a time; the next cycle re-asks
  Sync.question = question
  Sync.state = "question"
end

function Sync.answer(choice)
  local q = Sync.question
  Sync.question = nil
  Sync.state = "idle"
  if not q then return end
  if choice == "keep_local" or choice == "replace_server" then
    -- the player chose this device's copy: upload with their confirm
    Sync.push(q.key, q.slot, true)
  elseif choice == "take_server" then
    Sync.pull(q.slot, q.key)
  end
  -- "later" simply drops the question; the mismatch re-asks next cycle
  -- the player forces one (nothing nags every frame -- see update()).
end

-- --------------------------------------------------------------- ops

--- Compose the label a slot shows in the list: game + trainer + badges.
local function labelFor(rec)
  local parts = { tostring(rec.version):upper() }
  local trainer = rec.save and rec.save.player and rec.save.player.name
  if trainer then parts[#parts + 1] = tostring(trainer) end
  local badges = rec.summary and rec.summary.badges
  if badges then parts[#parts + 1] = tostring(badges) .. "B" end
  return table.concat(parts, " "):sub(1, 40)
end

--- Upload one key to a slot. confirm=true only ever arrives from a
--- player's explicit answer. cb(ok, err) optional.
function Sync.push(key, slot, confirm, cb)
  local link, why = readyLink()
  if not link then
    if cb then cb(nil, why) end
    return
  end
  local rec = Store.readAllLocal()[key]
  if not rec then
    if cb then cb(nil, "that save is no longer on this device") end
    return
  end
  local b = bindingOf(key) or {}
  local version = Store.versionOfKey(key)
  local pid = key:sub(#version + 2)
  Sync.state, Sync.status = "working", "Sending save..."
  link:upload(slot, { game = version, playthrough = pid, label = labelFor(rec) },
    rec.bytes, b.rev or 0, confirm == true,
    function(rev, err, have)
      if rev then
        setBinding(key, { slot = slot, rev = rev, hash = rec.hash })
        Sync.state, Sync.status = "idle", nil
        Sync.syncedSeq = Sync.syncedSeq + 1
        Sync.noteLanded(key)
        if cb then cb(true) end
      elseif err == "sync_conflict" then
        ask({ kind = "both_moved", key = key, slot = slot, have = have,
              localLabel = labelFor(rec) })
        if cb then cb(nil, err) end
      elseif err == "slot_conflict" then
        ask({ kind = "slot_conflict", key = key, slot = slot, have = have,
              localLabel = labelFor(rec) })
        if cb then cb(nil, err) end
      else
        Sync.state = "error"
        Sync.status = Sync.describeError(err)
        if cb then cb(nil, err) end
      end
    end)
end

--- Download a slot and apply it to the local playthrough it names. Only
--- ever called AFTER the player chose it -- downloads always ask first.
--- Applies immediately at the title screen; defers while a session is
--- live (the running game would write the old save back over it).
function Sync.pull(slot, key, cb)
  local link, why = readyLink()
  if not link then
    if cb then cb(nil, why) end
    return
  end
  Sync.state, Sync.status = "working", "Fetching save..."
  link:download(slot, function(bytes, err, meta)
    if not bytes then
      Sync.state = "error"
      Sync.status = Sync.describeError(err)
      if cb then cb(nil, err) end
      return
    end
    local gotKey = meta.game .. "-" .. meta.playthrough
    if key and gotKey ~= key then
      -- the slot was rebound between the ask and the answer; re-ask
      Sync.state, Sync.status = "idle", "That slot changed; check it again"
      if cb then cb(nil, "changed") end
      return
    end
    local landing = { slot = slot, key = gotKey, bytes = bytes, meta = meta }
    if Sync.canApplyDownload and not Sync.canApplyDownload() then
      pendingDownload = landing
      Sync.deferred = true
      Sync.state, Sync.status = "idle", "Save ready; lands at the title screen"
      if cb then cb(true, "deferred") end
      return
    end
    Sync.applyLanding(landing, cb)
  end)
end

function Sync.applyLanding(landing, cb)
  local version = Store.versionOfKey(landing.key)
  local ok, err = Store.apply(version, landing.key, landing.bytes, "cloud")
  if ok then
    setBinding(landing.key, { slot = landing.slot, rev = landing.meta.rev,
                              hash = hashOf(landing.bytes) })
    Sync.state, Sync.status = "idle", nil
    Sync.syncedSeq = Sync.syncedSeq + 1
    Sync.deferred = false
    Sync.noteLanded(landing.key)
    if cb then cb(true) end
  else
    Sync.state = "error"
    Sync.status = tostring(err or "could not apply the save")
    if cb then cb(nil, err) end
  end
end

--- Clear a slot on the server (the screen asks before calling).
function Sync.clearSlot(slot, cb)
  local link, why = readyLink()
  if not link then if cb then cb(nil, why) end return end
  link:clear(slot, function(ok, err)
    if ok then
      local key = Sync.keyForSlot(slot)
      if key then Sync.unbind(key) end
    end
    if cb then cb(ok, err) end
  end)
end

-- --------------------------------------------------------------- cycle

--- The game just wrote a save. Uploads (of bound keys) follow after a
--- short settle; nothing else is triggered by saving.
function Sync.markSaved()
  if not Sync.configured() then return end
  local c = Store.config()
  if c.auto == false then return end
  dirtyAt = now()
end

--- The player asked (Sync Now): push every bound key that differs, and
--- refresh the slot list while at it.
function Sync.request()
  if not Sync.configured() then return end
  dirtyAt = now() - UPLOAD_DELAY
  local link = select(1, readyLink())
  if link then link:list(function() end) end
end

--- Push every bound key whose bytes moved since the last agreement.
local function pushDirty()
  local link = select(1, readyLink())
  if not link then return end
  local locals = Store.readAllLocal()
  for key, b in pairs(Store.config().bindings or {}) do
    local rec = locals[key]
    if rec and b.slot and rec.hash ~= b.hash then
      Sync.push(key, b.slot)
      return -- one at a time; the next cycle takes the next key
    end
  end
  dirtyAt = nil
end

--- A sync landed for `key`: stamp the when (the gate shows "last synced"),
--- and retire any boot news it answered.
function Sync.noteLanded(key)
  local c = Store.config()
  c.lastSync = Util.now()
  Store.saveConfig(c)
  if Sync.bootNews then
    Sync.bootNews[key] = nil
    if not next(Sync.bootNews) then
      Sync.bootNews = nil
      if Sync.boot == "behind" then Sync.boot = "ok" end
    end
  end
end

-- Boot check driver (gate.lua wires the CONTINUE screen to Sync.boot).
local bootStartedAt = nil

function Sync.startBoot()
  if not Sync.configured() then
    Sync.boot = "off"
    return
  end
  if not Link.transportAvailable() then
    Sync.boot = "offline"
    return
  end
  Sync.boot = "checking"
  Sync.bootNews = nil
  bootStartedAt = now()
  local link = select(1, readyLink())
  if link then link:list(function(slots) Sync.finishBoot(slots) end) end
end

function Sync.finishBoot(slots)
  if not slots then
    Sync.boot = "offline"
    return
  end
  local byName = {}
  for _, s in ipairs(slots) do byName[s.slot] = s end
  local locals = Store.readAllLocal()
  local news = {}
  for key, b in pairs(Store.config().bindings or {}) do
    local server = byName[b.slot]
    local rec = locals[key]
    if server and not server.expired and rec then
      local verdict = Sync.assess(rec.hash, server.hash, b.hash)
      if verdict == "ask_download" or verdict == "ask_both" then
        news[key] = b.slot
      end
    end
  end
  Sync.bootNews = next(news) and news or nil
  Sync.boot = Sync.bootNews and "behind" or "ok"
end

--- Per-frame pump, called from the render hook.
function Sync.update()
  if Sync.link then
    Sync.link:update()
    -- a boot check whose connection died must not spin forever
    if Sync.boot == "checking" then
      if Sync.link.state == "error" then
        Sync.boot = (Sync.link.errorCode == "bad_proof") and "error" or "offline"
      elseif bootStartedAt and now() - bootStartedAt > 20 then
        Sync.boot = "offline"
      end
    end
    if Sync.state == "working" and Sync.link.state == "error" then
      Sync.state, Sync.status = "error", Sync.link.status or "Connection lost"
    end
  end

  -- a deferred download lands the moment the session allows it
  if pendingDownload and (not Sync.canApplyDownload or Sync.canApplyDownload()) then
    local landing = pendingDownload
    pendingDownload = nil
    Sync.applyLanding(landing)
  end

  -- settled after a save: push what moved
  if dirtyAt and now() - dirtyAt >= UPLOAD_DELAY
    and Sync.state ~= "working" and Sync.state ~= "question" then
    pushDirty()
  end
end

-- --------------------------------------------------------------- wording

--- Protocol codes -> sentences a player can act on. The name_taken wording
--- carries the one-account-two-mods fact, per the design: the account IS a
--- Gen1MMO account.
function Sync.describeError(code)
  local words = {
    name_taken = "That name already has an account. SaveSync and Gen1MMO"
      .. " share accounts -- if it's yours, just LOG IN with your Gen1MMO"
      .. " password.",
    look_alike = "That name looks too much like an existing account's.",
    bad_name = "Names are 3-16 letters, numbers or _.",
    bad_proof = "Wrong name or password.",
    banned = "That account is banned from the server.",
    registration_limited = "Too many new accounts from here; try later.",
    rate_limited = "Slow down a moment.",
    too_big = "That save is too large to sync.",
    upload_broken = "The upload arrived damaged; try again.",
    download_corrupt = "The download arrived damaged; try again.",
    not_found = "That slot is empty (or its save expired).",
    superseded = "Another device took over syncing this account.",
    bad_identity = "Server identity check FAILED -- not syncing.",
    no_tunnel = "The server would not encrypt; not syncing.",
    offline = "Could not reach the server.",
  }
  return words[code] or ("Sync problem: " .. tostring(code))
end

return Sync
