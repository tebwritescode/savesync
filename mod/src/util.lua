-- Small shared helpers: base64, content hashing, ids, time formatting.
--
-- LÖVE 11+ ships love.data.encode/decode/hash, which are C and correct.
-- Everything here prefers those and keeps a pure-Lua fallback so the module
-- still loads under a headless test harness (and so a future LÖVE that drops
-- a codec does not take the mod down with it).

local Util = {}

local haveData = love and love.data and love.data.encode and love.data.decode

-- ---------------------------------------------------------------- base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64Pure(data)
  local out, i = {}, 1
  while i + 2 <= #data do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + b * 256 + c
    out[#out + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
      .. B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
      .. B64:sub(n % 64 + 1, n % 64 + 1)
    i = i + 3
  end
  local rest = #data - i + 1
  if rest == 1 then
    local n = data:byte(i) * 65536
    out[#out + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1) .. "=="
  elseif rest == 2 then
    local n = data:byte(i) * 65536 + data:byte(i + 1) * 256
    out[#out + 1] = B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
      .. B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) .. "="
  end
  return table.concat(out)
end

local B64_INV = {}
for i = 1, 64 do B64_INV[B64:sub(i, i)] = i - 1 end

local function unb64Pure(s)
  s = s:gsub("[^A-Za-z0-9+/=]", "")
  local out, i = {}, 1
  while i <= #s do
    local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1),
      s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
    local n = (B64_INV[c1] or 0) * 262144 + (B64_INV[c2] or 0) * 4096
      + (B64_INV[c3] or 0) * 64 + (B64_INV[c4] or 0)
    out[#out + 1] = string.char(math.floor(n / 65536))
    if c3 ~= "=" and c3 ~= "" then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if c4 ~= "=" and c4 ~= "" then out[#out + 1] = string.char(n % 256) end
    i = i + 4
  end
  return table.concat(out)
end

function Util.b64(data)
  if haveData then
    local ok, s = pcall(love.data.encode, "string", "base64", data)
    if ok then return (s:gsub("[\r\n]", "")) end
  end
  return b64Pure(data)
end

function Util.unb64(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s", "")
  if haveData then
    local ok, d = pcall(love.data.decode, "string", "base64", s)
    if ok then return d end
  end
  return unb64Pure(s)
end

--- URL-safe base64 without padding -- what setup codes and OAuth PKCE use,
--- so a code survives being pasted into a browser bar or a chat app.
function Util.b64url(data)
  return (Util.b64(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

function Util.unb64url(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("-", "+"):gsub("_", "/")
  local pad = (4 - #s % 4) % 4
  return Util.unb64(s .. ("="):rep(pad))
end

-- ------------------------------------------------------------------ hash

local function toHex(raw)
  return (raw:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

-- Fallback digest for a host without love.data.hash: two independent
-- multiplicative rolls plus the length, hex-packed to look like the SHA-1 it
-- stands in for.  This is a CHANGE DETECTOR, not a security primitive, and
-- the protocol only ever compares hashes for equality -- but it must be
-- LuaJIT-safe, so no 5.3 bitwise operators appear anywhere in it.
local function rollingHex(s)
  local a, b = 5381, 52711
  for i = 1, #s do
    local c = s:byte(i)
    a = (a * 33 + c) % 0x100000000
    b = (b * 31 + c * (i % 251 + 1)) % 0x100000000
  end
  return ("%08x%08x%08x"):format(a, b, #s % 0x100000000)
end

--- Content hash of a save blob.  SHA-1 where LÖVE offers it (the same digest
--- git names objects with, which makes a GitHub-backed store pleasant to
--- inspect by hand), the rolling fallback otherwise.  The value is opaque to
--- the protocol: both sides only ever compare it for equality.
function Util.hash(data)
  if love and love.data and love.data.hash then
    local ok, raw = pcall(love.data.hash, "sha1", data)
    if ok and raw then return toHex(raw) end
  end
  return rollingHex(data)
end

function Util.short(hash)
  return tostring(hash or ""):sub(1, 8)
end

-- -------------------------------------------------------------------- id

local idSeq = 0

--- A random-enough opaque id.  Used for the device id and for OAuth PKCE
--- verifiers, both of which only need "different on every install".
function Util.randomId(bytes)
  bytes = bytes or 16
  local out = {}
  for _ = 1, bytes do
    local n
    if love and love.math and love.math.random then
      n = love.math.random(0, 255)
    else
      n = math.random(0, 255)
    end
    out[#out + 1] = string.char(n)
  end
  idSeq = idSeq + 1
  -- stir in the clock and a counter so two installs booted from the same
  -- image with the same RNG seed still differ
  local stamp = ("%08x%04x"):format(os.time() % 0x100000000, idSeq % 0x10000)
  return toHex(table.concat(out)):sub(1, bytes * 2 - #stamp) .. stamp
end

-- ------------------------------------------------------------------ time

function Util.now()
  return os.time()
end

--- "Just now" / "5 minutes ago" / "3 days ago" -- the only time format the
--- player-facing screen shows.
function Util.ago(t)
  if type(t) ~= "number" or t <= 0 then return "never" end
  local d = os.difftime(os.time(), t)
  if d < 0 then return "just now" end
  if d < 60 then return "just now" end
  if d < 3600 then
    local m = math.floor(d / 60)
    return m .. (m == 1 and " minute ago" or " minutes ago")
  end
  if d < 86400 then
    local h = math.floor(d / 3600)
    return h .. (h == 1 and " hour ago" or " hours ago")
  end
  local days = math.floor(d / 86400)
  return days .. (days == 1 and " day ago" or " days ago")
end

--- Compact stamp for backup filenames; sorts lexicographically by age.
function Util.stamp(t)
  return os.date("!%Y%m%d-%H%M%S", t or os.time())
end

function Util.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- Build an application/x-www-form-urlencoded body from a flat table.
function Util.form(t)
  local parts, keys = {}, {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = Util.urlencode(k) .. "=" .. Util.urlencode(t[k])
  end
  return table.concat(parts, "&")
end

--- Parse an application/x-www-form-urlencoded response (GitHub's token
--- endpoint still answers in this by default).
function Util.parseForm(s)
  local out = {}
  for k, v in tostring(s):gmatch("([^&=]+)=([^&]*)") do
    out[k] = (v:gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end):gsub("%+", " "))
  end
  return out
end

return Util
