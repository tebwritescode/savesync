-- Client-side crypto for Gen1MMO, built on LÖVE's native primitives.
--
-- love.data.hash gives fast native SHA-256, and love.data.encode/decode give
-- base64/hex. On top of those we build HMAC-SHA256 and PBKDF2 in a few lines.
--
-- The password KDF is PBKDF2-HMAC-SHA256, NOT scrypt: the client's job is only
-- to (a) never send the raw password and (b) produce a stable 32-byte verifier.
-- The server applies its own memory-hard scrypt to what we send, so the
-- at-rest hardening lives there. Native SHA-256 keeps this fast and, crucially,
-- correct without a Lua crypto dependency.

local Crypto = {}

-- LuaJIT's bit library is not guaranteed to be a global; pull it explicitly.
local bit = rawget(_G, "bit") or require("bit")

local BLOCK = 64 -- SHA-256 block size

--- Raw SHA-256 bytes of a string.
function Crypto.sha256(data)
  return love.data.hash("sha256", data)
end

function Crypto.toHex(raw)
  return love.data.encode("string", "hex", raw)
end

function Crypto.fromHex(hex)
  return love.data.decode("string", "hex", hex)
end

function Crypto.toBase64(raw)
  return love.data.encode("string", "base64", raw)
end

function Crypto.fromBase64(b64)
  return love.data.decode("string", "base64", b64)
end

local function xorBytes(a, b)
  local out = {}
  for i = 1, #a do
    out[i] = string.char(bit.bxor(a:byte(i), b:byte(i)))
  end
  return table.concat(out)
end

--- HMAC-SHA256(key, message) -> raw 32 bytes.
function Crypto.hmac(key, message)
  if #key > BLOCK then key = Crypto.sha256(key) end
  key = key .. string.rep("\0", BLOCK - #key)
  local opad, ipad = {}, {}
  for i = 1, BLOCK do
    local k = key:byte(i)
    opad[i] = string.char(bit.bxor(k, 0x5c))
    ipad[i] = string.char(bit.bxor(k, 0x36))
  end
  opad = table.concat(opad)
  ipad = table.concat(ipad)
  return Crypto.sha256(opad .. Crypto.sha256(ipad .. message))
end

--- PBKDF2-HMAC-SHA256 producing a single 32-byte block (dkLen = 32).
--- Deterministic: same (password, salt, iters) -> same verifier every login.
-- 20k rounds: the client KDF only needs to (a) never send the raw password and
-- (b) be stable. The server layers memory-hard scrypt on top, so this stays
-- modest to keep the one-time login derivation quick in pure Lua.
function Crypto.pbkdf2(password, salt, iters)
  iters = iters or 20000
  -- U1 = HMAC(pw, salt || INT32BE(1))
  local u = Crypto.hmac(password, salt .. "\0\0\0\1")
  local result = u
  for _ = 2, iters do
    u = Crypto.hmac(password, u)
    result = xorBytes(result, u)
  end
  return result -- raw 32 bytes
end

--- Derive the login/registration verifier the server expects, base64.
function Crypto.verifier(password, saltHex)
  local salt = Crypto.fromHex(saltHex)
  return Crypto.toBase64(Crypto.pbkdf2(password, salt))
end

--- Random hex string of n bytes, for the client-chosen registration salt.
function Crypto.randomHex(n)
  local bytes = {}
  for i = 1, n do bytes[i] = string.char(love.math.random(0, 255)) end
  return Crypto.toHex(table.concat(bytes))
end

--- Solve a hashcash proof-of-work: find a decimal nonce whose
--- SHA-256(challenge .. nonce) has >= bits leading zero bits.
--- Runs in slices via a coroutine so it never freezes the frame (see net pump).
function Crypto.powSolver(challenge, bits)
  local fullBytes = math.floor(bits / 8)
  local remBits = bits % 8
  local mask = 0
  if remBits > 0 then mask = bit.lshift(0xFF, 8 - remBits) end
  mask = bit.band(mask, 0xFF)

  return coroutine.create(function()
    local n = 0
    while true do
      local digest = love.data.hash("sha256", challenge .. tostring(n))
      local ok = true
      for i = 1, fullBytes do
        if digest:byte(i) ~= 0 then ok = false; break end
      end
      if ok and remBits > 0 then
        if bit.band(digest:byte(fullBytes + 1), mask) ~= 0 then ok = false end
      end
      if ok then return tostring(n) end
      n = n + 1
      -- Yield every ~2000 tries so the game keeps rendering while solving.
      if n % 2000 == 0 then coroutine.yield() end
    end
  end)
end

return Crypto
