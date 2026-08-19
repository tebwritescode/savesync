-- Two-device integration test for the v2 sync engine.
--
--   luajit tests/sync.test.lua
--
-- Two independent "devices" -- each with its own in-memory filesystem, its
-- own copies of the mod's modules and its own config -- over ONE fake
-- server that implements the cloud-slot rules EXACTLY as the real one does
-- (gen1mmo-server src/sync/slots.ts): lineage binding, baseRev optimistic
-- concurrency, confirm-only replacement, tombstone expiry.
--
-- The stories, in the owner's words:
--   * new progress uploads silently; EVERYTHING else asks
--   * two saves for the same game never overwrite each other
--   * saves for different games (red/yellow/gold) never overwrite each other
--   * a save untouched for 30 days expires to a visible tombstone
--   * a conflict never resolves itself; either answer keeps the loser
--     recoverable somewhere

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

-- ------------------------------------------------------------- the server
--
-- One account's five slots, with the real refusal rules. `today` is a dial
-- so expiry is a number the test turns, not a month it waits.

local function sha(s)
  -- deterministic stand-in hash; both sides use the same one via the fake
  -- crypto module below, so equality semantics match production exactly
  local h1, h2 = 1, 0
  for i = 1, #s do
    h1 = (h1 * 31 + s:byte(i)) % 2147483647
    h2 = (h2 + s:byte(i) * i) % 2147483647
  end
  return h1 .. "-" .. h2 .. "-" .. #s
end

local server = {
  slots = {},   -- [n] = {game, playthrough, label, bytes, hash, rev, updatedDay}
  today = 100,
  maxSlots = 5,
  expiryDays = 30,
}

function server.sweep()
  for _, s in pairs(server.slots) do
    if s.bytes and server.today - s.updatedDay > server.expiryDays then
      s.bytes = nil
    end
  end
end

function server.list()
  server.sweep()
  local out = {}
  for n, s in pairs(server.slots) do
    out[#out + 1] = {
      slot = n, game = s.game, playthrough = s.playthrough, label = s.label,
      size = s.size, hash = s.hash, rev = s.rev,
      expired = s.bytes == nil,
      expiresIn = s.bytes and math.max(0, server.expiryDays - (server.today - s.updatedDay)) or 0,
    }
  end
  table.sort(out, function(a, b) return a.slot < b.slot end)
  return out
end

function server.check(slot, game, pid, baseRev, confirm)
  if slot < 1 or slot > server.maxSlots then return nil, "bad_slot" end
  local s = server.slots[slot]
  if s and not confirm then
    local have = { game = s.game, playthrough = s.playthrough, label = s.label,
                   rev = s.rev, expired = s.bytes == nil }
    if s.game ~= game or s.playthrough ~= pid then
      return nil, "slot_conflict", have
    end
    if s.rev ~= baseRev then
      return nil, "sync_conflict", have
    end
  end
  return true
end

function server.put(slot, game, pid, label, bytes, baseRev, confirm)
  local ok, err, have = server.check(slot, game, pid, baseRev, confirm)
  if not ok then return nil, err, have end
  local s = server.slots[slot]
  local rev = (s and s.rev or 0) + 1
  server.slots[slot] = { game = game, playthrough = pid, label = label,
    bytes = bytes, size = #bytes, hash = sha(bytes), rev = rev,
    updatedDay = server.today }
  return rev
end

function server.read(slot)
  server.sweep()
  local s = server.slots[slot]
  if not s or not s.bytes then return nil, "not_found" end
  return s.bytes, { game = s.game, playthrough = s.playthrough, label = s.label,
    rev = s.rev, hash = s.hash,
    expiresIn = math.max(0, server.expiryDays - (server.today - s.updatedDay)) }
end

function server.clear(slot)
  server.slots[slot] = nil
  return true
end

-- ------------------------------------------------------------ a device

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

  local slots = { active = {}, list = {} }  -- per version
  local function versionSlots(version)
    slots.list[version] = slots.list[version] or {}
    return slots.list[version]
  end
  dev.saveData = {
    saveFilename = function(version)
      local a = slots.active[version]
      return a and ("saves/" .. version .. "/" .. a .. ".lua") or nil
    end,
    activeSlot = function(version) return slots.active[version] end,
    listSlots = function(version)
      local out = {}
      for _, id in ipairs(versionSlots(version)) do
        out[#out + 1] = { id = id,
          exists = dev.disk["saves/" .. version .. "/" .. id .. ".lua"] ~= nil }
      end
      return out
    end,
    createSlot = function(version)
      local list = versionSlots(version)
      local maxN = 0
      for _, id in ipairs(list) do
        local n = tonumber(tostring(id):match("^slot(%d+)$"))
        if n and n > maxN then maxN = n end
      end
      local id = "slot" .. (maxN + 1)
      list[#list + 1] = id
      return id
    end,
    setActiveSlot = function(version, id) slots.active[version] = id end,
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
    VERSIONS = { red = {}, yellow = {}, gold = {} },
    info = function(id)
      return id == "red" or id == "yellow" or id == "gold"
    end,
    get = function() return "red" end,
    ORDER = { "red", "yellow", "gold" },
  }

  dev.cache = {}
  dev.include = function(path)
    if dev.cache[path] then return dev.cache[path] end
    local chunk = assert(loadfile("mod/" .. path))
    local v = chunk()
    dev.cache[path] = v
    return v
  end

  -- crypto without LOVE: the deterministic hash above; base64 unused here
  dev.cache["src/crypto.lua"] = {
    sha256 = function(s) return s end,
    toHex = function(s) return sha(s) end,
    toBase64 = function(s) return s end,
    fromBase64 = function(s) return s end,
    verifier = function() return "VERIFIER" end,
    randomHex = function(n) return string.rep("ab", n) end,
  }

  -- the fake link: the serverlink API surface over the fake server,
  -- synchronous. state mirrors what sync.lua reads.
  local FakeLink = {}
  FakeLink.__index = FakeLink
  FakeLink.transportAvailable = function() return true end
  FakeLink.probe = function() return true end
  FakeLink.new = function(opts)
    local link = setmetatable({
      state = "offline", slots = nil, maxSlots = server.maxSlots,
      expiryDays = server.expiryDays, onEvent = opts.onEvent,
    }, FakeLink)
    dev.link = link
    return link
  end
  function FakeLink:loginStored(name, verifier)
    if dev.offline then
      self.state = "error"
      self.errorCode = "offline"
      self.status = "Could not reach the server"
      return true
    end
    self.state = "ready"
    self.name = name
    self.slots = server.list()
    return true
  end
  function FakeLink:register(name, password)
    self.state = "ready"
    self.name = name
    self.slots = server.list()
    if self.onEvent then
      self.onEvent("credentials", { name = name, verifier = "VERIFIER" })
      self.onEvent("recovery_code", "G1MMO-FAKE-CODE")
    end
    self.recoveryCode = "G1MMO-FAKE-CODE"
    return true
  end
  FakeLink.login = FakeLink.register
  function FakeLink:ready() return self.state == "ready" end
  function FakeLink:disconnect() self.state = "offline" end
  function FakeLink:update() end
  function FakeLink:list(cb)
    self.slots = server.list()
    cb(self.slots)
  end
  function FakeLink:download(slot, cb)
    local bytes, meta = server.read(slot)
    if bytes then cb(bytes, nil, meta) else cb(nil, meta or "not_found") end
  end
  function FakeLink:upload(slot, meta, bytes, baseRev, confirm, cb)
    local rev, err, have = server.put(slot, meta.game, meta.playthrough,
      meta.label, bytes, baseRev, confirm)
    if rev then cb(rev, nil, { expiresIn = server.expiryDays })
    else cb(nil, err, have) end
  end
  function FakeLink:clear(slot, cb)
    cb(server.clear(slot))
  end
  dev.cache["src/serverlink.lua"] = FakeLink

  return dev
end

local function activate(dev)
  _G.love = dev.love
  _G.SAVESYNC_INCLUDE = dev.include
  package.loaded["src.core.SaveData"] = dev.saveData
  package.loaded["src.core.SaveSerializer"] = dev.serializer
  package.loaded["src.core.GameVersion"] = dev.gameVersion
  if not dev.Sync then
    dev.Store = dev.include("src/store.lua")
    dev.Sync = dev.include("src/sync.lua")
    dev.Sync.init({ host = "test", port = 1, pin = "PIN", version = "2.0.0" })
    -- sign in (the fake link answers instantly)
    dev.Sync.login("Ash", "pw")
    dev.Sync.update()
  end
  return dev.Sync, dev.Store
end

local function play(dev, version, slotId, tbl)
  activate(dev)
  local list = dev.slots.list[version] or {}
  local found = false
  for _, id in ipairs(list) do if id == slotId then found = true end end
  if not found then
    dev.slots.list[version] = dev.slots.list[version] or {}
    table.insert(dev.slots.list[version], slotId)
  end
  dev.slots.active[version] = dev.slots.active[version] or slotId
  dev.saveData.writeSlot(version, slotId, tbl)
end

local function pump(dev, frames)
  activate(dev)
  for _ = 1, frames or 300 do dev.Sync.update() end
end

local function localSave(dev, version, slotId)
  activate(dev)
  local rec = dev.Store.readSlot(version, slotId)
  return rec and rec.save or nil
end

-- ------------------------------------------------------------ the story

local A = newDevice("A")
local B = newDevice("B")

-- 1. A signs in and sends its Red save to cloud slot 1, by choice.
play(A, "red", "slot1", { version = "red", player = { name = "RED" }, badges = 1,
  meta = { playthroughId = "aaaa0001" } })
do
  local Sync = activate(A)
  eq("A is configured after login", Sync.configured(), true)
  local done, okPush
  Sync.push("red-aaaa0001", 1, false, function(ok) done, okPush = true, ok end)
  pump(A, 10)
  check("the push completed", done)
  eq("and succeeded", okPush, true)
  check("the server holds it", server.slots[1] ~= nil)
  eq("bound at rev 1", Sync.bindingFor("red-aaaa0001") and Sync.bindingFor("red-aaaa0001").rev, 1)
end

-- 2. B adopts it -- explicitly, because downloads always ask; the "ask"
-- here is the test calling pull, exactly as the UI does after its confirm.
do
  local Sync, Store = activate(B)
  local done, okPull
  Sync.pull(1, nil, function(ok) done, okPull = true, ok end)
  pump(B, 10)
  check("the pull completed", done)
  eq("and succeeded", okPull, true)
  local save = localSave(B, "red", "slot1")
  check("B now has the save", save ~= nil)
  eq("with the right trainer", save and save.player.name, "RED")
  eq("B's binding matches the server rev",
    Sync.bindingFor("red-aaaa0001") and Sync.bindingFor("red-aaaa0001").rev, 1)
end

-- 3. A plays on and SAVES: the one silent flow. markSaved + update pushes
-- with no question asked.
play(A, "red", "slot1", { version = "red", player = { name = "RED" }, badges = 2,
  meta = { playthroughId = "aaaa0001" } })
do
  local Sync = activate(A)
  Sync.markSaved()
  -- the settle delay is wall-clock; force it due
  Sync.request()
  pump(A, 20)
  eq("A's new progress fast-forwarded up, silently", server.slots[1].rev, 2)
  eq("no question was raised", Sync.question, nil)
end

-- 4. B boots: the server has news. That is a QUESTION (the gate shows it);
-- nothing lands by itself.
do
  local Sync = activate(B)
  Sync.startBoot()
  pump(B, 10)
  eq("boot sees the server is ahead", Sync.boot, "behind")
  local save = localSave(B, "red", "slot1")
  eq("and B's save is UNTOUCHED", save.badges, 1)
  -- the player answers (via the gate's Use server save)
  local key = next(Sync.bootNews)
  eq("the news names the right save", key, "red-aaaa0001")
  Sync.pull(Sync.bootNews[key], key, function() end)
  pump(B, 10)
  eq("after the player's yes, B has the progress", localSave(B, "red", "slot1").badges, 2)
  eq("and the boot verdict clears", Sync.boot, "ok")
end

-- 5. THE CASE THAT MATTERS: both change the same save without syncing.
play(A, "red", "slot1", { version = "red", player = { name = "RED" }, badges = 3,
  meta = { playthroughId = "aaaa0001" } })
play(B, "red", "slot1", { version = "red", player = { name = "RED" }, badges = 5,
  meta = { playthroughId = "aaaa0001" } })
do
  local SyncA = activate(A)
  SyncA.push("red-aaaa0001", 1, false, function() end)
  pump(A, 10)
  eq("A publishes first", server.slots[1].rev, 3)

  local SyncB = activate(B)
  SyncB.push("red-aaaa0001", 1, false, function() end)
  pump(B, 10)
  check("B's push was refused into a question", SyncB.question ~= nil)
  eq("of the both-moved kind", SyncB.question and SyncB.question.kind, "both_moved")
  eq("the server copy STANDS (badges 3 upload)", server.slots[1].rev, 3)
  eq("B's local copy stands too", localSave(B, "red", "slot1").badges, 5)

  -- the player picks the server's copy; B's own is backed up first
  SyncB.answer("take_server")
  pump(B, 10)
  eq("B adopted the server copy", localSave(B, "red", "slot1").badges, 3)
  local hasBackup = false
  for k in pairs(B.disk) do
    if k:match("^savesync/backups/red%-aaaa0001/") then hasBackup = true end
  end
  check("B's overwritten save is in local backups", hasBackup)
end

-- 6. The same conflict answered the OTHER way: keep local, replace server.
play(A, "red", "slot1", { version = "red", player = { name = "RED" }, badges = 6,
  meta = { playthroughId = "aaaa0001" } })
play(B, "red", "slot1", { version = "red", player = { name = "RED" }, badges = 7,
  meta = { playthroughId = "aaaa0001" } })
do
  local SyncA = activate(A)
  SyncA.push("red-aaaa0001", 1, false, function() end)
  pump(A, 10)
  local SyncB = activate(B)
  SyncB.push("red-aaaa0001", 1, false, function() end)
  pump(B, 10)
  check("again a question", SyncB.question ~= nil)
  SyncB.answer("keep_local")
  pump(B, 10)
  check("the player's confirm replaced the server copy", server.slots[1].rev > 4)
  check("with B's bytes", server.slots[1].bytes:find('"badges"%]=7') ~= nil)
  eq("A still holds its own copy locally", localSave(A, "red", "slot1").badges, 6)
end

-- 7. TWO SAVES, SAME GAME: a second Red playthrough cannot land on the
-- first's slot without the player.
play(A, "red", "slot2", { version = "red", player = { name = "ASH2" }, badges = 0,
  meta = { playthroughId = "bbbb0002" } })
do
  local Sync = activate(A)
  local err
  Sync.push("red-bbbb0002", 1, false, function(_, e) err = e end)
  pump(A, 10)
  eq("the slot refuses a different playthrough", err, "slot_conflict")
  check("and raises the question", Sync.question ~= nil and Sync.question.kind == "slot_conflict")
  Sync.answer("later")
  check("the first playthrough's bytes are untouched",
    server.slots[1].bytes:find('"badges"%]=7') ~= nil)
  -- into its own slot instead: clean
  local ok2
  Sync.push("red-bbbb0002", 2, false, function(ok) ok2 = ok end)
  pump(A, 10)
  eq("its own slot takes it without a question", ok2, true)
end

-- 8. DIFFERENT GAMES: gold and red isolate by construction.
play(A, "gold", "slot1", { version = "gold", player = { name = "GOLD" }, badges = 2,
  meta = { playthroughId = "cccc0003" } })
do
  local Sync = activate(A)
  local err
  Sync.push("gold-cccc0003", 1, false, function(_, e) err = e end)
  pump(A, 10)
  eq("gold into the red slot is refused", err, "slot_conflict")
  Sync.answer("later")
  local ok3
  Sync.push("gold-cccc0003", 3, false, function(ok) ok3 = ok end)
  pump(A, 10)
  eq("gold into its own slot lands", ok3, true)
  eq("three slots, three lineages", server.slots[3].game, "gold")

  -- and a download of the gold slot lands in gold's save dir on B
  local SyncB = activate(B)
  SyncB.pull(3, nil, function() end)
  pump(B, 10)
  local gsave = localSave(B, "gold", "slot1")
  check("gold landed under gold on B", gsave ~= nil and gsave.version == "gold")
  check("and did not touch B's red save",
    localSave(B, "red", "slot1") ~= nil)
end

-- 9. EXPIRY: 31 days pass; the red slot's bytes are swept, the tombstone
-- shows, the boot check does not cry wolf, and re-upload revives it.
server.today = server.today + 31
do
  local Sync = activate(A)
  local listed
  Sync.link:list(function(l) listed = l end)
  check("the slot lists as expired", (function()
    for _, s in ipairs(listed or {}) do
      if s.slot == 1 and s.expired then return true end
    end
  end)())
  Sync.startBoot()
  pump(A, 10)
  check("an expired slot is not 'news'", Sync.boot ~= "behind")

  local err
  Sync.pull(1, nil, function(_, e) err = e end)
  pump(A, 10)
  eq("downloading an expired slot answers not_found", err, "not_found")

  -- re-upload revives (same lineage, stored rev): use B, whose binding
  -- rev matches what the server last held
  local SyncB = activate(B)
  local okRevive
  SyncB.push("red-aaaa0001", 1, false, function(ok) okRevive = ok end)
  pump(B, 10)
  eq("re-upload revives the tombstone", okRevive, true)
  check("bytes are back", server.slots[1].bytes ~= nil)
end

-- 10. Logout hygiene: account gone, bindings gone, recovery code kept.
do
  local Sync, Store = activate(B)
  Sync.logout()
  eq("logged out", Sync.configured(), false)
  eq("bindings cleared", Sync.keyForSlot(1), nil)
  eq("recovery code kept", Store.config().recoveryCode, "G1MMO-FAKE-CODE")
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
