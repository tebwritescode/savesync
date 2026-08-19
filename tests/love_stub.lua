-- A LuaJIT-native stand-in for the LÖVE surfaces the mod's crypto and
-- tunnel reach: love.data.hash (SHA-256, pure Lua over the bit library),
-- love.data.encode/decode (base64 + hex), love.math.random, love.timer.
--
-- WHY PURE LUA SHA-256. The live e2e runs the SHIPPED tunnel.lua against
-- the real server: HKDF, HMAC and the transcript hash must byte-match
-- Node's crypto or the handshake fails -- which makes the handshake itself
-- the test vector. The implementation below is additionally checked
-- against the FIPS "abc" vector at load, so a broken shim fails here with
-- a plain message rather than as a mysterious rejected hello.

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift

local function rrot(x, n) return bor(rshift(x, n), lshift(x, 32 - n)) % 0x100000000 end

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256(msg)
  local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local len = #msg
  msg = msg .. "\128" .. ("\0"):rep((55 - len) % 64)
    .. string.char(0, 0, 0, 0,
      band(rshift(len * 8, 24), 255), band(rshift(len * 8, 16), 255),
      band(rshift(len * 8, 8), 255), band(len * 8, 255))
  local w = {}
  for block = 1, #msg, 64 do
    for i = 0, 15 do
      local o = block + i * 4
      w[i + 1] = bor(lshift(msg:byte(o), 24), lshift(msg:byte(o + 1), 16),
        lshift(msg:byte(o + 2), 8), msg:byte(o + 3)) % 0x100000000
    end
    for i = 17, 64 do
      local s0 = bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3))
      local s1 = bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 0x100000000
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for i = 1, 64 do
      local S1 = bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25))
      local ch = bxor(band(e, f), band(bnot(e) % 0x100000000, g))
      local t1 = (hh + S1 + ch + K[i] + w[i]) % 0x100000000
      local S0 = bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = (S0 + maj) % 0x100000000
      hh, g, f, e, d, c, b, a =
        g, f, e, (d + t1) % 0x100000000, c, b, a, (t1 + t2) % 0x100000000
    end
    h[1] = (h[1] + a) % 0x100000000
    h[2] = (h[2] + b) % 0x100000000
    h[3] = (h[3] + c) % 0x100000000
    h[4] = (h[4] + d) % 0x100000000
    h[5] = (h[5] + e) % 0x100000000
    h[6] = (h[6] + f) % 0x100000000
    h[7] = (h[7] + g) % 0x100000000
    h[8] = (h[8] + hh) % 0x100000000
  end
  local out = {}
  for i = 1, 8 do
    out[#out + 1] = string.char(band(rshift(h[i], 24), 255),
      band(rshift(h[i], 16), 255), band(rshift(h[i], 8), 255), band(h[i], 255))
  end
  return table.concat(out)
end


-- ---- SHA-512, 64-bit words as {hi, lo} pairs over the 32-bit bit library.
-- Needed by the tunnel's Ed25519 verification. Self-tested below like
-- SHA-256: a wrong implementation fails at load, not as a rejected hello.

local K512 = {
  {0x428a2f98,0xd728ae22},{0x71374491,0x23ef65cd},{0xb5c0fbcf,0xec4d3b2f},{0xe9b5dba5,0x8189dbbc},
  {0x3956c25b,0xf348b538},{0x59f111f1,0xb605d019},{0x923f82a4,0xaf194f9b},{0xab1c5ed5,0xda6d8118},
  {0xd807aa98,0xa3030242},{0x12835b01,0x45706fbe},{0x243185be,0x4ee4b28c},{0x550c7dc3,0xd5ffb4e2},
  {0x72be5d74,0xf27b896f},{0x80deb1fe,0x3b1696b1},{0x9bdc06a7,0x25c71235},{0xc19bf174,0xcf692694},
  {0xe49b69c1,0x9ef14ad2},{0xefbe4786,0x384f25e3},{0x0fc19dc6,0x8b8cd5b5},{0x240ca1cc,0x77ac9c65},
  {0x2de92c6f,0x592b0275},{0x4a7484aa,0x6ea6e483},{0x5cb0a9dc,0xbd41fbd4},{0x76f988da,0x831153b5},
  {0x983e5152,0xee66dfab},{0xa831c66d,0x2db43210},{0xb00327c8,0x98fb213f},{0xbf597fc7,0xbeef0ee4},
  {0xc6e00bf3,0x3da88fc2},{0xd5a79147,0x930aa725},{0x06ca6351,0xe003826f},{0x14292967,0x0a0e6e70},
  {0x27b70a85,0x46d22ffc},{0x2e1b2138,0x5c26c926},{0x4d2c6dfc,0x5ac42aed},{0x53380d13,0x9d95b3df},
  {0x650a7354,0x8baf63de},{0x766a0abb,0x3c77b2a8},{0x81c2c92e,0x47edaee6},{0x92722c85,0x1482353b},
  {0xa2bfe8a1,0x4cf10364},{0xa81a664b,0xbc423001},{0xc24b8b70,0xd0f89791},{0xc76c51a3,0x0654be30},
  {0xd192e819,0xd6ef5218},{0xd6990624,0x5565a910},{0xf40e3585,0x5771202a},{0x106aa070,0x32bbd1b8},
  {0x19a4c116,0xb8d2d0c8},{0x1e376c08,0x5141ab53},{0x2748774c,0xdf8eeb99},{0x34b0bcb5,0xe19b48a8},
  {0x391c0cb3,0xc5c95a63},{0x4ed8aa4a,0xe3418acb},{0x5b9cca4f,0x7763e373},{0x682e6ff3,0xd6b2b8a3},
  {0x748f82ee,0x5defb2fc},{0x78a5636f,0x43172f60},{0x84c87814,0xa1f0ab72},{0x8cc70208,0x1a6439ec},
  {0x90befffa,0x23631e28},{0xa4506ceb,0xde82bde9},{0xbef9a3f7,0xb2c67915},{0xc67178f2,0xe372532b},
  {0xca273ece,0xea26619c},{0xd186b8c7,0x21c0c207},{0xeada7dd6,0xcde0eb1e},{0xf57d4f7f,0xee6ed178},
  {0x06f067aa,0x72176fba},{0x0a637dc5,0xa2c898a6},{0x113f9804,0xbef90dae},{0x1b710b35,0x131c471b},
  {0x28db77f5,0x23047d84},{0x32caab7b,0x40c72493},{0x3c9ebe0a,0x15c9bebc},{0x431d67c4,0x9c100d4c},
  {0x4cc5d4be,0xcb3e42b6},{0x597f299c,0xfc657e2a},{0x5fcb6fab,0x3ad6faec},{0x6c44198c,0x4a475817},
}

local function u32n(x) return x % 0x100000000 end

local function add64(ah, al, bh, bl)
  -- LuaJIT's bit ops return SIGNED 32-bit values; the carry is only right
  -- over the unsigned representatives, so normalise first.
  ah, al, bh, bl = u32n(ah), u32n(al), u32n(bh), u32n(bl)
  local lo = al + bl
  local hi = ah + bh + math.floor(lo / 0x100000000)
  return u32n(hi), u32n(lo)
end

local function not64(ah, al) return u32n(bnot(ah)), u32n(bnot(al)) end

local function rotr64(ah, al, n)
  if n == 32 then return al, ah end
  if n < 32 then
    return u32n(bor(rshift(ah, n), lshift(al, 32 - n))),
           u32n(bor(rshift(al, n), lshift(ah, 32 - n)))
  end
  n = n - 32
  return u32n(bor(rshift(al, n), lshift(ah, 32 - n))),
         u32n(bor(rshift(ah, n), lshift(al, 32 - n)))
end

local function shr64(ah, al, n)
  if n < 32 then
    return rshift(ah, n), u32n(bor(rshift(al, n), lshift(ah, 32 - n)))
  end
  return 0, rshift(ah, n - 32)
end

local function sha512(msg)
  local H = {
    {0x6a09e667,0xf3bcc908},{0xbb67ae85,0x84caa73b},{0x3c6ef372,0xfe94f82b},{0xa54ff53a,0x5f1d36f1},
    {0x510e527f,0xade682d1},{0x9b05688c,0x2b3e6c1f},{0x1f83d9ab,0xfb41bd6b},{0x5be0cd19,0x137e2179},
  }
  local len = #msg
  msg = msg .. "\128" .. ("\0"):rep((111 - len) % 128)
    .. ("\0"):rep(8)
    .. string.char(
      band(rshift(math.floor(len * 8 / 0x100000000), 24), 255),
      band(rshift(math.floor(len * 8 / 0x100000000), 16), 255),
      band(rshift(math.floor(len * 8 / 0x100000000), 8), 255),
      band(math.floor(len * 8 / 0x100000000), 255),
      band(rshift(len * 8, 24), 255), band(rshift(len * 8, 16), 255),
      band(rshift(len * 8, 8), 255), band(len * 8, 255))
  local wh, wl = {}, {}
  for block = 1, #msg, 128 do
    for i = 0, 15 do
      local o = block + i * 8
      wh[i + 1] = u32n(bor(lshift(msg:byte(o), 24), lshift(msg:byte(o + 1), 16),
        lshift(msg:byte(o + 2), 8), msg:byte(o + 3)))
      wl[i + 1] = u32n(bor(lshift(msg:byte(o + 4), 24), lshift(msg:byte(o + 5), 16),
        lshift(msg:byte(o + 6), 8), msg:byte(o + 7)))
    end
    for i = 17, 80 do
      local ah1, al1 = rotr64(wh[i-15], wl[i-15], 1)
      local ah2, al2 = rotr64(wh[i-15], wl[i-15], 8)
      local ah3, al3 = shr64(wh[i-15], wl[i-15], 7)
      local s0h, s0l = bxor(ah1, ah2, ah3), bxor(al1, al2, al3)
      local bh1, bl1 = rotr64(wh[i-2], wl[i-2], 19)
      local bh2, bl2 = rotr64(wh[i-2], wl[i-2], 61)
      local bh3, bl3 = shr64(wh[i-2], wl[i-2], 6)
      local s1h, s1l = bxor(bh1, bh2, bh3), bxor(bl1, bl2, bl3)
      local th, tl = add64(wh[i-16], wl[i-16], s0h, s0l)
      th, tl = add64(th, tl, wh[i-7], wl[i-7])
      th, tl = add64(th, tl, s1h, s1l)
      wh[i], wl[i] = th, tl
    end
    local ah, al = H[1][1], H[1][2]
    local bh, bl = H[2][1], H[2][2]
    local ch, cl = H[3][1], H[3][2]
    local dh, dl = H[4][1], H[4][2]
    local eh, el = H[5][1], H[5][2]
    local fh, fl = H[6][1], H[6][2]
    local gh, gl = H[7][1], H[7][2]
    local hh, hl = H[8][1], H[8][2]
    for i = 1, 80 do
      local x1h, x1l = rotr64(eh, el, 14)
      local x2h, x2l = rotr64(eh, el, 18)
      local x3h, x3l = rotr64(eh, el, 41)
      local S1h, S1l = bxor(x1h, x2h, x3h), bxor(x1l, x2l, x3l)
      local nh, nl = not64(eh, el)
      local chh = bxor(band(eh, fh), band(nh, gh))
      local chl = bxor(band(el, fl), band(nl, gl))
      local t1h, t1l = add64(hh, hl, S1h, S1l)
      t1h, t1l = add64(t1h, t1l, chh, chl)
      t1h, t1l = add64(t1h, t1l, K512[i][1], K512[i][2])
      t1h, t1l = add64(t1h, t1l, wh[i], wl[i])
      local y1h, y1l = rotr64(ah, al, 28)
      local y2h, y2l = rotr64(ah, al, 34)
      local y3h, y3l = rotr64(ah, al, 39)
      local S0h, S0l = bxor(y1h, y2h, y3h), bxor(y1l, y2l, y3l)
      local majh = bxor(band(ah, bh), band(ah, ch), band(bh, ch))
      local majl = bxor(band(al, bl), band(al, cl), band(bl, cl))
      local t2h, t2l = add64(S0h, S0l, majh, majl)
      hh, hl = gh, gl
      gh, gl = fh, fl
      fh, fl = eh, el
      eh, el = add64(dh, dl, t1h, t1l)
      dh, dl = ch, cl
      ch, cl = bh, bl
      bh, bl = ah, al
      ah, al = add64(t1h, t1l, t2h, t2l)
    end
    H[1][1], H[1][2] = add64(H[1][1], H[1][2], ah, al)
    H[2][1], H[2][2] = add64(H[2][1], H[2][2], bh, bl)
    H[3][1], H[3][2] = add64(H[3][1], H[3][2], ch, cl)
    H[4][1], H[4][2] = add64(H[4][1], H[4][2], dh, dl)
    H[5][1], H[5][2] = add64(H[5][1], H[5][2], eh, el)
    H[6][1], H[6][2] = add64(H[6][1], H[6][2], fh, fl)
    H[7][1], H[7][2] = add64(H[7][1], H[7][2], gh, gl)
    H[8][1], H[8][2] = add64(H[8][1], H[8][2], hh, hl)
  end
  local out = {}
  for i = 1, 8 do
    for _, v in ipairs({ H[i][1], H[i][2] }) do
      out[#out + 1] = string.char(band(rshift(v, 24), 255),
        band(rshift(v, 16), 255), band(rshift(v, 8), 255), band(v, 255))
    end
  end
  return table.concat(out)
end

local function toHex(raw)
  return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function fromHex(hex)
  return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- FIPS 180-2 "abc": a broken shim must fail HERE, not as a rejected hello.
assert(toHex(sha256("abc"))
  == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  "love_stub: sha256 self-test failed")

-- FIPS 180-2 "abc" for SHA-512
assert(toHex(sha512("abc")):sub(1, 64)
  == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a",
  "love_stub: sha512 self-test failed")

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(data)
  return ((data:gsub("...", function(chunk)
    local n = chunk:byte(1) * 65536 + chunk:byte(2) * 256 + chunk:byte(3)
    return B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
      .. B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
      .. B64:sub(n % 64 + 1, n % 64 + 1)
  end)) .. ({ "", "==", "=" })[#data % 3 + 1])
end
local function b64encodeFull(data)
  local rem = #data % 3
  local body = data:sub(1, #data - rem)
  local out = b64encode(body)
  if rem == 1 then
    local n = data:byte(#data) * 65536
    out = out .. B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1) .. "=="
  elseif rem == 2 then
    local n = data:byte(#data - 1) * 65536 + data:byte(#data) * 256
    out = out .. B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
      .. B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) .. "="
  end
  return out
end
local REV = {}
for i = 1, #B64 do REV[B64:sub(i, i)] = i - 1 end
local function b64decode(s)
  s = s:gsub("[^%w%+/=]", "")
  local out = {}
  local n, bits = 0, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c ~= "=" then
      local v = REV[c]
      if v == nil then return nil end
      n = n * 64 + v
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        out[#out + 1] = string.char(math.floor(n / 2 ^ bits) % 256)
        -- KEEP THE ACCUMULATOR BOUNDED. Without this line n grows
        -- monotonically and sails past 2^53 after a dozen characters --
        -- every byte after that is silently wrong. The original self-test
        -- vector was four characters long, which is exactly how it passed.
        n = n % 2 ^ bits
      end
    end
  end
  return table.concat(out)
end

assert(b64encodeFull("Man") == "TWFu" and b64encodeFull("Ma") == "TWE="
  and b64encodeFull("M") == "TQ==" and b64decode("TWFu") == "Man",
  "love_stub: base64 self-test failed")
-- and a LONG binary round trip, because the short vectors above hid a
-- precision bug that corrupted every decode past a dozen characters
do
  local blob = {}
  for i = 0, 255 do blob[#blob + 1] = string.char(i, (i * 7) % 256, 255 - i) end
  local raw = table.concat(blob)
  assert(b64decode(b64encodeFull(raw)) == raw,
    "love_stub: base64 long round-trip failed")
end

math.randomseed(os.time() + (os.clock() * 1000000) % 1000000)

love = {
  data = {
    hash = function(fn, data)
      if fn == "sha256" then return sha256(data) end
      if fn == "sha512" then return sha512(data) end
      error("love_stub: unsupported hash " .. tostring(fn))
    end,
    encode = function(_, fmt, data)
      if fmt == "hex" then return toHex(data) end
      if fmt == "base64" then return b64encodeFull(data) end
      error("love_stub: unknown encode " .. tostring(fmt))
    end,
    decode = function(_, fmt, data)
      if fmt == "hex" then return fromHex(data) end
      if fmt == "base64" then
        local v = b64decode(data)
        if v == nil then error("bad base64") end
        return v
      end
      error("love_stub: unknown decode " .. tostring(fmt))
    end,
  },
  math = { random = function(a, b) return math.random(a, b) end },
  timer = { getTime = function() return os.clock() end },
  system = { getOS = function() return "TestHost" end },
}

return love
