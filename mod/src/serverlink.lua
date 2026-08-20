-- The SaveSync server session: one account, one encrypted tunnel, five
-- cloud slots. This is the only file that speaks the wire protocol.
--
-- The server is the Gen1MMO server -- same host, same port, same tunnel,
-- same account. SaveSync logs in with mode="sync", which lands the session
-- in a state whose whole vocabulary is the sync_* frames: no world, no
-- roster, no chat. An account registered here IS a Gen1MMO account, and
-- both mods say so where it matters.
--
-- TRANSPORT. Non-blocking luasocket pumped once a frame, sealed with the
-- pure-Lua tunnel (X25519 + ChaCha20-Poly1305, the server's Ed25519 key
-- pinned in this source). LOVE vendors luasocket on every platform this
-- engine ships on -- desktop, Android, iOS -- so there is no curl, no
-- worker thread and no platform TLS anywhere in this mod any more. The
-- tunnel is the confidentiality layer, not the platform.
--
-- SHAPE. Connect-on-demand: a session exists while there is work (a sync,
-- a screen open, a boot check) and closes when idle. Every operation is
-- queued and runs strictly one at a time -- the server holds one upload
-- per session, and a queue is simpler than being clever.

local Net = SAVESYNC_INCLUDE("src/net.lua")
local Tunnel = SAVESYNC_INCLUDE("src/tunnel.lua")
local Crypto = SAVESYNC_INCLUDE("src/crypto.lua")

local Link = {}
Link.__index = Link

-- Raw bytes per upload part; must match the server's SYNC.partBytes budget
-- (frame guard: 2048 chars per string, 4096 per frame).
local PART_BYTES = 1500
-- A session with nothing queued closes after this many seconds; the server
-- reaps idle sockets anyway, and a deliberate close is tidier.
local IDLE_CLOSE = 45

function Link.new(opts)
  return setmetatable({
    host = opts.host, port = opts.port, pin = opts.pin,
    version = opts.version or "?",
    state = "offline",       -- offline|connecting|authing|ready|error
    status = nil,            -- one human sentence for the UI
    errorCode = nil,         -- last protocol error code, for wording
    name = nil,              -- logged-in account name once ready
    slots = nil,             -- cached slot list (sync_welcome / sync_slots)
    maxSlots = 5, expiryDays = 30,
    recoveryCode = nil,      -- set by registered/recovered; shown ONCE
    onEvent = opts.onEvent,  -- optional: fn(kind, data) for the UI/sync
    _queue = {},             -- pending ops, strictly serial
    _active = nil,           -- the op in flight
    _idleAt = nil,
  }, Link)
end

-- --------------------------------------------------------- capability

function Link.transportAvailable()
  return Net.transportAvailable()
end

function Link.probe(host, port, timeout)
  return Net.probe(host, port, timeout)
end

-- --------------------------------------------------------- lifecycle

local function isLoopback(host)
  return host == "localhost" or host == "::1" or tostring(host):sub(1, 4) == "127."
end

local function b64maybe(s)
  if type(s) ~= "string" then return nil end
  local ok, raw = pcall(Crypto.fromBase64, s)
  return ok and raw or nil
end

--- Open the socket and start the handshake. `auth` is what to do once the
--- tunnel is up: { intent = "register"|"login"|"login_stored"|"recover",
--- name, password, code (recover), verifier (stored) }.
function Link:_open(auth)
  if self.net then self.net:close() end
  self.net = Net.new()
  -- A device keypair (passkey-style). Generated fresh at register if the
  -- shared credential does not already hold one; reused otherwise. The seed
  -- is 32 bytes; the server stores only the public key.
  auth.device = auth.device or {}
  if not auth.device.seed and auth.intent == "register" then
    auth.device.seed = Crypto.fromHex(Crypto.randomHex(32))
    auth.device.pub = Tunnel.edPublicKey(auth.device.seed)
    auth.device.enrolled = false
  end
  self._auth = auth
  self.errorCode = nil
  self.recoveryCode = nil
  self.state = "connecting"
  self.status = "Connecting..."
  if not self.net:connect(self.host, self.port) then
    self.state = "error"
    self.status = self.net.error or "Could not reach the server"
    return false
  end
  self._hs = Tunnel.start(Tunnel.gatherEntropy(
    tostring(self.host) .. ":" .. tostring(self.port)))
  self.net:send({ type = "hello", v = 1, cpub = Crypto.toBase64(self._hs.cpub),
                  client = "savesync/" .. tostring(self.version) })
  self.status = "Securing the connection..."
  return true
end

function Link:disconnect()
  if self.net then self.net:close() end
  self.net = nil
  self._hs = nil
  self._active, self._queue = nil, {}
  self._powCo = nil
  self.state = "offline"
  self.name = nil
  self.status = nil
end

function Link:_fail(status, code)
  self.state = "error"
  self.status = status
  self.errorCode = code
  -- every queued op fails with the same answer; nothing hangs
  local active, queue = self._active, self._queue
  self._active, self._queue = nil, {}
  if active and active.cb then pcall(active.cb, nil, code or "offline") end
  for _, op in ipairs(queue) do
    if op.cb then pcall(op.cb, nil, code or "offline") end
  end
  if self.net then self.net:close() end
  self.net = nil
end

-- --------------------------------------------------------- auth entries

--- Begin a session. Credentials never persist here: the caller keeps the
--- (name, derived verifier) pair; passwords are burned to verifiers at the
--- first opportunity and never stored anywhere.
function Link:register(name, password, device)
  return self:_open({ intent = "register", name = name, password = password, device = device })
end

function Link:login(name, password, device)
  return self:_open({ intent = "login", name = name, password = password, device = device })
end

--- Sign in with the derived verifier remembered from a previous session.
--- `device` = { seed, pub, enrolled } carries the passkey-style device key so
--- a returning device signs the login nonce instead of sending the verifier.
function Link:loginStored(name, verifier, device)
  return self:_open({ intent = "login_stored", name = name, verifier = verifier, device = device })
end

--- Recovery: prove the one-time code, set a new password. On success the
--- server issues a FRESH code (one-shot rule) which lands in
--- self.recoveryCode exactly like registration's.
function Link:recover(name, code, newPassword, device)
  return self:_open({ intent = "recover", name = name, code = code,
                      password = newPassword, device = device })
end

function Link:ready()
  return self.state == "ready"
end

-- --------------------------------------------------------- slot ops
-- Each returns immediately; the callback fires when the server answers.
-- cb(result, errCode, extra) -- result nil on failure.

local function enqueue(self, op)
  self._queue[#self._queue + 1] = op
  self._idleAt = nil
end

--- Refresh the slot list. cb(slots) with the same shape the cache holds.
function Link:list(cb)
  enqueue(self, { kind = "list", cb = cb })
end

--- Download one slot. cb(bytes, err, meta).
function Link:download(slot, cb)
  enqueue(self, { kind = "get", slot = slot, cb = cb })
end

--- Upload bytes into a slot. meta = { game, playthrough, label }.
--- baseRev = the rev this device last saw for the slot (0 = believes empty).
--- confirm = the player's explicit yes to replace something.
--- cb(rev, errCode, have) -- `have` carries the server's holding on
--- slot_conflict / sync_conflict, so the caller can ask the player.
function Link:upload(slot, meta, bytes, baseRev, confirm, cb)
  enqueue(self, { kind = "put", slot = slot, meta = meta, bytes = bytes,
                  baseRev = baseRev or 0, confirm = confirm == true, cb = cb })
end

--- Free a slot. The caller asks the player first; the server obeys.
function Link:clear(slot, cb)
  enqueue(self, { kind = "clear", slot = slot, cb = cb })
end

-- --------------------------------------------------------- the pump

function Link:_startOp(op)
  self._active = op
  if op.kind == "list" then
    self.net:send({ type = "sync_list" })
  elseif op.kind == "get" then
    op.parts = {}
    self.net:send({ type = "sync_get", slot = op.slot })
  elseif op.kind == "put" then
    self.net:send({
      type = "sync_put_begin", slot = op.slot,
      game = op.meta.game, playthrough = op.meta.playthrough,
      label = op.meta.label or "",
      size = #op.bytes, hash = Crypto.toHex(Crypto.sha256(op.bytes)),
      baseRev = op.baseRev, confirm = op.confirm,
    })
  elseif op.kind == "clear" then
    self.net:send({ type = "sync_clear", slot = op.slot })
  end
end

function Link:_finishOp(result, err, extra)
  local op = self._active
  self._active = nil
  if op and op.cb then pcall(op.cb, result, err, extra) end
end

--- One protocol error while an op is in flight answers that op; the
--- conflict codes are QUESTIONS and must not tear the session down.
local SOFT_ERRORS = {
  slot_conflict = true, sync_conflict = true, not_found = true,
  too_big = true, bad_slot = true, upload_busy = true, upload_broken = true,
  rate_limited = true,
}

function Link:_onMessage(m)
  local t = m.type

  if t == "hello_ack" then
    -- Pin policy, strictest first: the pinned key MUST verify. An
    -- unpinned remote gets an encrypted-but-unverified session only on
    -- loopback (dev server); a remote server that will not encrypt is
    -- refused outright.
    if m.spub then
      local pin = self.pin and b64maybe(self.pin) or nil
      local sess = self._hs and Tunnel.finish(self._hs, b64maybe(m.spub), b64maybe(m.sig), pin)
      self._hs = nil
      if not sess then
        return self:_fail("Server identity check FAILED", "bad_identity")
      end
      self.net.tunnel = sess
    elseif not isLoopback(self.host) then
      return self:_fail("Server refused encryption", "no_tunnel")
    end
    -- tunnel (or loopback) up: run the auth intent
    local a = self._auth
    self.state = "authing"
    if a.intent == "register" then
      self.status = "Requesting registration..."
      self.net:send({ type = "pow_get" })
    elseif a.intent == "recover" then
      self.status = "Checking your recovery code..."
      a.clientSalt = Crypto.randomHex(16)
      a.newVerifier = Crypto.verifier(a.password, a.clientSalt)
      a.password = nil
      self.net:send({ type = "recover", name = a.name, code = a.code,
                      clientSalt = a.clientSalt, verifier = a.newVerifier })
    else
      self.status = "Signing in..."
      self.net:send({ type = "salt_get", name = a.name })
    end

  elseif t == "pow" then
    -- proof of work rides a coroutine so a slow device still draws frames
    self._powId = m.id
    self._powCo = Crypto.powSolver(m.challenge, m.bits)
    self.status = "Proving you're human..."

  elseif t == "salt" then
    local a = self._auth
    if a.intent == "login_stored" then
      a.pendingVerifier = a.verifier
    else
      a.pendingVerifier = Crypto.verifier(a.password, m.salt)
      a.password = nil
    end
    -- Build the proof. A returning ENROLLED device signs the fresh nonce and
    -- sends NO verifier -- non-replayable, no password on the wire. A device
    -- that is not yet enrolled sends the verifier (and its pubkey), so the
    -- server enrols the key on this password-verified login.
    local frame = { type = "login", mode = "sync", name = a.name }
    local dev = a.device
    if dev and dev.seed and m.nonce then
      frame.deviceKey = Crypto.toHex(dev.pub)
      frame.deviceSig = Crypto.toBase64(Tunnel.edSign(dev.seed, m.nonce .. ":" .. a.name))
      if not dev.enrolled then frame.verifier = a.pendingVerifier end
    else
      frame.verifier = a.pendingVerifier
    end
    self.net:send(frame)

  elseif t == "registered" or t == "recovered" then
    self.recoveryCode = m.recoveryCode
    if self.onEvent then pcall(self.onEvent, "recovery_code", m.recoveryCode) end
    if t == "recovered" then
      -- recovery is not a session: log in with the new password's verifier
      local a = self._auth
      self.status = "Password set. Signing in..."
      self.net:send({ type = "login", mode = "sync", name = a.name,
                      verifier = a.newVerifier })
      a.pendingVerifier, a.pendingSalt = a.newVerifier, a.clientSalt
    end

  elseif t == "sync_welcome" then
    self.state = "ready"
    self.name = m.name
    self.maxSlots = m.maxSlots or 5
    self.expiryDays = m.expiryDays or 30
    self.slots = m.slots or {}
    self.status = "Signed in as " .. tostring(m.name)
    local a = self._auth
    if a and self.onEvent then
      -- hand the derived verifier AND the device key up for storage; never a
      -- password. A successful sign-in means the device key is now enrolled
      -- server-side, so future logins can go signature-only.
      local dev = a.device or {}
      pcall(self.onEvent, "credentials", {
        name = m.name,
        verifier = a.pendingVerifier,
        deviceSeed = dev.seed and Crypto.toHex(dev.seed) or nil,
        devicePub = dev.pub and Crypto.toHex(dev.pub) or nil,
        deviceEnrolled = (dev.seed ~= nil),
      })
    end
    self._auth = nil
    if self.onEvent then pcall(self.onEvent, "slots", self.slots) end

  elseif t == "sync_slots" then
    self.slots = m.slots or {}
    if self.onEvent then pcall(self.onEvent, "slots", self.slots) end
    if self._active and self._active.kind == "list" then
      self:_finishOp(self.slots)
    end

  elseif t == "sync_data" then
    local op = self._active
    if op and op.kind == "get" and m.slot == op.slot then
      op.parts[#op.parts + 1] = tostring(m.part or "")
    end

  elseif t == "sync_data_end" then
    local op = self._active
    if op and op.kind == "get" and m.slot == op.slot then
      local bytes = Crypto.fromBase64(table.concat(op.parts))
      -- verify against the declared hash: a save file that is almost
      -- right is a corrupted playthrough
      if Crypto.toHex(Crypto.sha256(bytes)) ~= m.hash then
        self:_finishOp(nil, "download_corrupt")
      else
        self:_finishOp(bytes, nil, {
          rev = m.rev, hash = m.hash, game = m.game,
          playthrough = m.playthrough, label = m.label,
          expiresIn = m.expiresIn,
        })
      end
    end

  elseif t == "sync_put_ready" then
    local op = self._active
    if op and op.kind == "put" then
      local b64 = Crypto.toBase64(op.bytes)
      local partChars = math.ceil(PART_BYTES * 4 / 3)
      local seq = 0
      for at = 1, #b64, partChars do
        seq = seq + 1
        self.net:send({ type = "sync_put_part", slot = op.slot, seq = seq,
                        part = b64:sub(at, at + partChars - 1) })
      end
      self.net:send({ type = "sync_put_end", slot = op.slot })
    end

  elseif t == "sync_saved" then
    local op = self._active
    if op and op.kind == "put" then
      self:_finishOp(m.rev, nil, { expiresIn = m.expiresIn })
    end

  elseif t == "sync_cleared" then
    local op = self._active
    if op and op.kind == "clear" then self:_finishOp(true) end

  elseif t == "error" then
    local code = tostring(m.code or "error")
    if self._active and SOFT_ERRORS[code] then
      self:_finishOp(nil, code, m.have and {
        game = m.have.game, playthrough = m.have.playthrough,
        label = m.have.label, rev = m.have.rev, expired = m.have.expired,
      } or nil)
    elseif self.state == "authing" then
      -- an auth refusal ends the attempt with the code intact: the UI
      -- words name_taken/bad_proof/banned itself (the name_taken wording
      -- is where "same account as Gen1MMO" lives)
      self:_fail(nil, code)
    elseif self._active then
      self:_finishOp(nil, code)
    end

  elseif t == "kick" then
    local reason = tostring(m.reason or "kicked")
    if reason == "superseded" then
      self:_fail("Another device took over this account's sync", "superseded")
    else
      self:_fail("Disconnected (" .. reason .. ")", reason)
    end
  end
end

--- Pump once a frame from the render hook. Drives the socket, the PoW
--- solver, the op queue and the idle close.
function Link:update()
  if not self.net then return end

  -- PoW coroutine: a few thousand hashes a frame, no dropped frames
  if self._powCo then
    local ok, nonce = coroutine.resume(self._powCo)
    if ok and nonce then
      self._powCo = nil
      local a = self._auth
      a.clientSalt = Crypto.randomHex(16)
      a.pendingVerifier = Crypto.verifier(a.password, a.clientSalt)
      a.password = nil
      self.net:send({
        type = "register", mode = "sync", name = a.name,
        clientSalt = a.clientSalt, verifier = a.pendingVerifier,
        powId = self._powId, powNonce = nonce,
        deviceKey = a.device.pub and Crypto.toHex(a.device.pub) or nil,
      })
      self.status = "Creating your account..."
    elseif not ok then
      self._powCo = nil
      self:_fail("Registration check failed", "bad_pow")
    end
  end

  self.net:update()
  if self.net and self.net.closed and self.state ~= "error" then
    return self:_fail(self.net.error or "Connection lost", "offline")
  end

  local batch = self.net and self.net:poll()
  if batch then
    for _, msg in ipairs(batch) do
      self:_onMessage(msg)
      if not self.net then return end -- a message may tear the session down
    end
  end

  -- start the next op / close when idle
  if self.state == "ready" and not self._active then
    local op = table.remove(self._queue, 1)
    if op then
      self._idleAt = nil
      self:_startOp(op)
    else
      local now = (love and love.timer and love.timer.getTime) and love.timer.getTime() or os.clock()
      self._idleAt = self._idleAt or now
      if now - self._idleAt > IDLE_CLOSE then
        self:disconnect()
      end
    end
  end
end

return Link
