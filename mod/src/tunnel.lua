-- Encrypted tunnel in pure Lua: X25519 key agreement, ChaCha20-Poly1305
-- framing, HKDF-SHA256, and Ed25519 signature verification of the pinned key.
-- Implements the Gen1MMO tunnel protocol v1 (hello/hello_ack handshake, then
-- one base64 AEAD frame per line, counter nonces, fail-closed on any mismatch).
--
-- NUMERIC MODEL. LÖVE runs LuaJIT, where Lua numbers are IEEE doubles (exact
-- integers only up to 2^53). Every routine here is written to stay within that
-- budget: ChaCha uses the bit library normalised to unsigned 32-bit, and the
-- curve/field code uses TweetNaCl's 16x16-bit limb layout (products < 2^53).
-- The same code therefore runs identically under Lua 5.4 (the test harness) and
-- LuaJIT (the game) -- validated byte-for-byte against Node's crypto.

local bit = rawget(_G, "bit") or require("bit")
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local Tunnel = {}

local TWO32 = 4294967296
local function u32(x) return x % TWO32 end                 -- normalise to [0,2^32)
local function rotl(x, n) return u32(bor(lshift(band(x, 0xFFFFFFFF), n), rshift(band(x, 0xFFFFFFFF), 32 - n))) end

-- ---------------------------------------------------------------- ChaCha20

local function chachaBlock(key, counter, nonce, out)
  -- key: 8 u32 (LE from 32 bytes), counter: u32, nonce: 3 u32
  local s = {
    0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
    key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8],
    counter, nonce[1], nonce[2], nonce[3],
  }
  local x = {}
  for i = 1, 16 do x[i] = s[i] end
  local function qr(a, b, c, d)
    x[a] = u32(x[a] + x[b]); x[d] = bxor(x[d], x[a]); x[d] = rotl(x[d], 16)
    x[c] = u32(x[c] + x[d]); x[b] = bxor(x[b], x[c]); x[b] = rotl(x[b], 12)
    x[a] = u32(x[a] + x[b]); x[d] = bxor(x[d], x[a]); x[d] = rotl(x[d], 8)
    x[c] = u32(x[c] + x[d]); x[b] = bxor(x[b], x[c]); x[b] = rotl(x[b], 7)
  end
  for _ = 1, 10 do
    qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15); qr(4, 8, 12, 16)
    qr(1, 6, 11, 16); qr(2, 7, 12, 13); qr(3, 8, 9, 14); qr(4, 5, 10, 15)
  end
  for i = 1, 16 do
    local v = u32(x[i] + s[i])
    local o = (i - 1) * 4
    out[o + 1] = band(v, 0xFF); out[o + 2] = band(rshift(v, 8), 0xFF)
    out[o + 3] = band(rshift(v, 16), 0xFF); out[o + 4] = band(rshift(v, 24), 0xFF)
  end
end

local function bytesToKeyWords(key32)
  local k = {}
  for i = 0, 7 do
    local o = i * 4 + 1
    k[i + 1] = u32(key32:byte(o) + key32:byte(o + 1) * 256
      + key32:byte(o + 2) * 65536 + key32:byte(o + 3) * 16777216)
  end
  return k
end

--- ChaCha20 keystream XOR. nonce is 12 bytes; initial counter as given.
local function chacha20(key32, counter0, nonce12, data)
  local key = bytesToKeyWords(key32)
  local nonce = {}
  for i = 0, 2 do
    local o = i * 4 + 1
    nonce[i + 1] = u32(nonce12:byte(o) + nonce12:byte(o + 1) * 256
      + nonce12:byte(o + 2) * 65536 + nonce12:byte(o + 3) * 16777216)
  end
  local out, block = {}, {}
  local counter = counter0
  local n = #data
  local pos = 1
  while pos <= n do
    chachaBlock(key, u32(counter), nonce, block)
    counter = counter + 1
    for i = 1, 64 do
      if pos > n then break end
      out[pos] = string.char(bxor(data:byte(pos), block[i]))
      pos = pos + 1
    end
  end
  return table.concat(out)
end

Tunnel.chacha20 = chacha20

-- ---------------------------------------------------------------- Poly1305

-- Poly1305 in 10 limbs of 13 bits. WHY 13: LuaJIT numbers are IEEE doubles,
-- so every intermediate must stay below 2^53 EXACTLY. 26-bit limbs put the
-- schoolbook products near 2^57 (silent rounding, wrong tags -- found in the
-- first real in-engine run); 13-bit limbs cap them near 2^33. Pure
-- arithmetic only (%, floor, *, +): bitwise ops on this path burned us once
-- via LuaJIT's signed 32-bit returns. Field packing is disjoint, so OR is +.
local function poly1305(msg, key32)
  local F = math.floor
  local function le16(s, o) return s:byte(o) + s:byte(o + 1) * 256 end
  local t = {}
  for i = 0, 7 do t[i] = le16(key32, i * 2 + 1) end
  -- r = 13-bit slices of clamp(key[1..16]). The sparse clamp masks keep only
  -- some bit ranges of a slice; "v % 4 + F(v / 256) * 256" style keeps the
  -- named ranges with pure arithmetic.
  local r = {}
  r[0] = t[0] % 8192
  r[1] = (F(t[0] / 8192) + t[1] * 8) % 8192
  local v2 = (F(t[1] / 1024) + t[2] * 64) % 8192
  r[2] = v2 % 4 + F(v2 / 256) * 256                -- & 0x1f03: bits 0-1, 8-12
  r[3] = (F(t[2] / 128) + t[3] * 512) % 8192
  r[4] = (F(t[3] / 16) + t[4] * 4096) % 256        -- & 0x00ff
  local v5 = F(t[4] / 2) % 8192
  r[5] = v5 - v5 % 2                               -- & 0x1ffe: bits 1-12
  r[6] = (F(t[4] / 16384) + t[5] * 4) % 8192
  local v7 = (F(t[5] / 2048) + t[6] * 32) % 8192
  r[7] = v7 % 2 + F(v7 / 128) * 128                -- & 0x1f81: bits 0, 7-12
  r[8] = (F(t[6] / 256) + t[7] * 256) % 8192
  r[9] = F(t[7] / 32) % 128                        -- & 0x007f
  local h = { [0]=0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  local n = #msg
  local pos = 1
  while pos <= n do
    local len = math.min(16, n - pos + 1)
    local blk
    if len == 16 then
      blk = msg:sub(pos, pos + 15)
    else
      -- RFC padding for the final short block: append 0x01, zero-fill, and
      -- DO NOT add the 2^128 bit for this block.
      blk = msg:sub(pos, pos + len - 1) .. "\1" .. string.rep("\0", 15 - len)
    end
    local m = {}
    for i = 0, 7 do m[i] = le16(blk, i * 2 + 1) end
    h[0] = h[0] + m[0] % 8192
    h[1] = h[1] + (F(m[0] / 8192) + m[1] * 8) % 8192
    h[2] = h[2] + (F(m[1] / 1024) + m[2] * 64) % 8192
    h[3] = h[3] + (F(m[2] / 128) + m[3] * 512) % 8192
    h[4] = h[4] + (F(m[3] / 16) + m[4] * 4096) % 8192
    h[5] = h[5] + F(m[4] / 2) % 8192
    h[6] = h[6] + (F(m[4] / 16384) + m[5] * 4) % 8192
    h[7] = h[7] + (F(m[5] / 2048) + m[6] * 32) % 8192
    h[8] = h[8] + (F(m[6] / 256) + m[7] * 256) % 8192
    h[9] = h[9] + F(m[7] / 32) + (len == 16 and 2048 or 0)
    -- h = (h * r) mod p, limbwise with the x5 wrap for limbs past 2^130
    local d = {}
    for i = 0, 9 do
      local acc = 0
      for j = 0, 9 do
        if j <= i then
          acc = acc + h[j] * r[i - j]
        else
          acc = acc + h[j] * 5 * r[i + 10 - j]
        end
      end
      d[i] = acc
    end
    local c = 0
    for i = 0, 9 do
      d[i] = d[i] + c
      c = F(d[i] / 8192)
      h[i] = d[i] % 8192
    end
    h[0] = h[0] + c * 5
    c = F(h[0] / 8192); h[0] = h[0] % 8192
    h[1] = h[1] + c
    pos = pos + 16
  end
  -- full carry: propagate twice so the x5 wrap's ripple settles everywhere
  local c = F(h[1] / 8192); h[1] = h[1] % 8192
  for i = 2, 9 do
    h[i] = h[i] + c
    c = F(h[i] / 8192); h[i] = h[i] % 8192
  end
  h[0] = h[0] + c * 5
  for i = 0, 9 do
    c = F(h[i] / 8192); h[i] = h[i] % 8192
    if i < 9 then h[i + 1] = h[i + 1] + c end
  end
  h[0] = h[0] + c * 5 -- c from h[9] is 0 in practice; keep the invariant anyway
  c = F(h[0] / 8192); h[0] = h[0] % 8192
  h[1] = h[1] + c
  -- p in these limbs is [2^13-5, 2^13-1 x9]; branch-subtract when h >= p
  local ge = h[0] >= 8187
  for i = 1, 9 do
    if h[i] ~= 8191 then ge = false end
  end
  if ge then
    h[0] = h[0] - 8187
    for i = 1, 9 do h[i] = 0 end
  end
  -- serialize to 8 LE u16 words (13-bit limbs -> 16-bit words), add s
  local w = {}
  w[0] = h[0] + (h[1] % 8) * 8192
  w[1] = F(h[1] / 8) + (h[2] % 64) * 1024
  w[2] = F(h[2] / 64) + (h[3] % 512) * 128
  w[3] = F(h[3] / 512) + (h[4] % 4096) * 16
  w[4] = F(h[4] / 4096) + h[5] * 2 + (h[6] % 4) * 16384
  w[5] = F(h[6] / 4) + (h[7] % 32) * 2048
  w[6] = F(h[7] / 32) + (h[8] % 256) * 256
  w[7] = F(h[8] / 256) + (h[9] % 2048) * 32
  local out = {}
  local carry = 0
  for i = 0, 7 do
    local v = w[i] + le16(key32, 17 + i * 2) + carry
    carry = F(v / 65536)
    v = v % 65536
    out[i * 2 + 1] = string.char(v % 256)
    out[i * 2 + 2] = string.char(F(v / 256))
  end
  return table.concat(out)
end

Tunnel.poly1305 = poly1305

-- ---------------------------------------------------------------- AEAD

local function pad16(n) local r = n % 16; return r == 0 and 0 or (16 - r) end

--- ChaCha20-Poly1305 (RFC 8439). Returns ciphertext .. tag(16). No AAD (the
--- server uses none). nonce is 12 bytes.
function Tunnel.aeadSeal(key32, nonce12, plaintext)
  local polyKey = chacha20(key32, 0, nonce12, string.rep("\0", 32))
  local ct = chacha20(key32, 1, nonce12, plaintext)
  local mac = string.rep("\0", pad16(#ct))
  local lenBlock = {}
  local aadLen, ctLen = 0, #ct
  for i = 0, 7 do lenBlock[i + 1] = string.char(band(rshift(aadLen, i * 8), 0xFF)) end
  for i = 0, 7 do lenBlock[i + 9] = string.char(band(math.floor(ctLen / (2 ^ (i * 8))), 0xFF)) end
  local tag = poly1305(ct .. mac .. table.concat(lenBlock), polyKey)
  return ct .. tag
end

--- Returns plaintext, or nil on tag mismatch.
function Tunnel.aeadOpen(key32, nonce12, sealed)
  if #sealed < 16 then return nil end
  local ct = sealed:sub(1, #sealed - 16)
  local tag = sealed:sub(#sealed - 15)
  local polyKey = chacha20(key32, 0, nonce12, string.rep("\0", 32))
  local mac = string.rep("\0", pad16(#ct))
  local lenBlock = {}
  local ctLen = #ct
  for i = 0, 7 do lenBlock[i + 1] = "\0" end
  for i = 0, 7 do lenBlock[i + 9] = string.char(band(math.floor(ctLen / (2 ^ (i * 8))), 0xFF)) end
  local expect = poly1305(ct .. mac .. table.concat(lenBlock), polyKey)
  if expect ~= tag then return nil end
  return chacha20(key32, 1, nonce12, ct)
end

-- ------------------------------------------------ curve25519 field (gf)
--
-- TweetNaCl's 16x16-bit limb arithmetic, ported with PLAIN Lua arithmetic
-- only (+ - * % math.floor): every intermediate stays far below 2^53, so the
-- code is exact on IEEE doubles and IDENTICAL under LuaJIT and Lua 5.4.
-- Deliberately no `bit` library in anything below this line -- LuaJIT's bit
-- ops return SIGNED 32-bit values, and mixing those into arithmetic is the
-- classic source of silent cross-VM divergence.
--
-- Branch-based select instead of masked constant-time select: a game client
-- doing one handshake per connection is not defensible against local timing
-- probes anyway, and branches keep the number model trivially correct.

local function gf(init)
  local o = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  if init then for i = 1, #init do o[i] = init[i] end end
  return o
end

local gf0 = gf()
local gf1 = gf({ 1 })
local _121665 = gf({ 0xdb41, 1 })
local D  = gf({ 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
                0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 })
local D2 = gf({ 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
                0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 })
local BX = gf({ 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
                0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 })
local BY = gf({ 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
                0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 })
local SQRTM1 = gf({ 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
                    0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 })
-- Group order L, little-endian bytes (2^252 + 27742317777372353535851937790883648493).
local LB = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
             0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

local function set25519(r, a) for i = 1, 16 do r[i] = a[i] end end

local function car25519(o)
  local c = 1
  for i = 1, 16 do
    local v = o[i] + c + 65535
    c = math.floor(v / 65536)
    o[i] = v - c * 65536
  end
  o[1] = o[1] + c - 1 + 37 * (c - 1)
end

--- Swap the CONTENTS of two field elements when b == 1.
local function sel25519(p, q, b)
  if b == 1 then
    for i = 1, 16 do p[i], q[i] = q[i], p[i] end
  end
end

local function pack25519(o, n) -- o: 32 bytes out (table), n: field element
  local t, m = gf(), gf()
  set25519(t, n)
  car25519(t); car25519(t); car25519(t)
  for _ = 1, 2 do
    m[1] = t[1] - 0xffed
    for i = 2, 15 do
      m[i] = t[i] - 0xffff - ((m[i - 1] < 0) and 1 or 0)
      m[i - 1] = m[i - 1] % 65536
    end
    m[16] = t[16] - 0x7fff - ((m[15] < 0) and 1 or 0)
    local underflow = m[16] < 0
    m[15] = m[15] % 65536
    if not underflow then set25519(t, m) end -- t >= p: take the reduced copy
  end
  for i = 1, 16 do
    o[2 * i - 1] = t[i] % 256
    o[2 * i] = math.floor(t[i] / 256)
  end
end

local function par25519(a)
  local d = {}
  pack25519(d, a)
  return d[1] % 2
end

local function neq25519(a, b)
  local da, db = {}, {}
  pack25519(da, a); pack25519(db, b)
  for i = 1, 32 do
    if da[i] ~= db[i] then return true end
  end
  return false
end

local function unpack25519(o, s) -- s: 32-byte string
  for i = 0, 15 do
    o[i + 1] = s:byte(2 * i + 1) + 256 * s:byte(2 * i + 2)
  end
  o[16] = o[16] % 32768
end

local function A(o, a, b) for i = 1, 16 do o[i] = a[i] + b[i] end end
local function Z(o, a, b) for i = 1, 16 do o[i] = a[i] - b[i] end end

local function M(o, a, b) -- schoolbook multiply + 2^255-19 fold; alias-safe
  local t = {}
  for i = 1, 31 do t[i] = 0 end
  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do
      t[i + j - 1] = t[i + j - 1] + ai * b[j]
    end
  end
  for i = 1, 15 do t[i] = t[i] + 38 * t[i + 16] end
  for i = 1, 16 do o[i] = t[i] end
  car25519(o); car25519(o)
end

local function S(o, a) M(o, a, a) end

local function inv25519(o, i) -- x^(p-2)
  local c = gf()
  set25519(c, i)
  for a = 253, 0, -1 do
    S(c, c)
    if a ~= 2 and a ~= 4 then M(c, c, i) end
  end
  set25519(o, c)
end

local function pow2523(o, i) -- x^((p-5)/8), for point decompression
  local c = gf()
  set25519(c, i)
  for a = 250, 0, -1 do
    S(c, c)
    if a ~= 1 then M(c, c, i) end
  end
  set25519(o, c)
end

local function bytesToStr(t, n)
  local out = {}
  for i = 1, n do out[i] = string.char(t[i]) end
  return table.concat(out)
end

-- ------------------------------------------------ X25519 (RFC 7748)

--- Montgomery-ladder scalar multiplication: x25519(scalar32, point32) -> 32 bytes.
function Tunnel.x25519(n, p)
  local z = {}
  for i = 1, 31 do z[i] = n:byte(i) end
  z[1] = z[1] - z[1] % 8                    -- clamp: low 3 bits cleared
  z[32] = 64 + (n:byte(32) % 128) % 64      -- clamp: top bit cleared, bit 6 set
  local x = gf()
  unpack25519(x, p)
  local a, b, c, d, e, f = gf(), gf(), gf(), gf(), gf(), gf()
  set25519(b, x)
  a[1] = 1; d[1] = 1
  for i = 254, 0, -1 do
    local r = math.floor(z[math.floor(i / 8) + 1] / 2 ^ (i % 8)) % 2
    sel25519(a, b, r); sel25519(c, d, r)
    A(e, a, c); Z(a, a, c); A(c, b, d); Z(b, b, d)
    S(d, e); S(f, a); M(a, c, a); M(c, b, e)
    A(e, a, c); Z(a, a, c); S(b, a); Z(c, d, f)
    M(a, c, _121665); A(a, a, d); M(c, c, a)
    M(a, d, f); M(d, b, x); S(b, e)
    sel25519(a, b, r); sel25519(c, d, r)
  end
  local inv, out, q = gf(), gf(), {}
  inv25519(inv, c)
  M(out, a, inv)
  pack25519(q, out)
  return bytesToStr(q, 32)
end

local BASEPOINT9 = "\9" .. string.rep("\0", 31)

function Tunnel.x25519Base(n)
  return Tunnel.x25519(n, BASEPOINT9)
end

-- ------------------------------------------------ Ed25519 verify (RFC 8032)

-- Extended-coordinate Edwards point ops (points are {X, Y, Z, T} of gf).

local function edAdd(p, q)
  local a, b, c, d, e, f, g, h, t = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
  Z(a, p[2], p[1]); Z(t, q[2], q[1]); M(a, a, t)
  A(b, p[1], p[2]); A(t, q[1], q[2]); M(b, b, t)
  M(c, p[4], q[4]); M(c, c, D2)
  M(d, p[3], q[3]); A(d, d, d)
  Z(e, b, a); Z(f, d, c); A(g, d, c); A(h, b, a)
  M(p[1], e, f); M(p[2], h, g); M(p[3], g, f); M(p[4], e, h)
end

local function edCswap(p, q, b)
  for k = 1, 4 do sel25519(p[k], q[k], b) end
end

local function edPack(p) -- -> 32-byte string
  local zi, tx, ty = gf(), gf(), gf()
  inv25519(zi, p[3])
  M(tx, p[1], zi); M(ty, p[2], zi)
  local d = {}
  pack25519(d, ty)
  local hi = math.floor(d[32] / 128)
  d[32] = (d[32] % 128) + 128 * ((hi + par25519(tx)) % 2)
  return bytesToStr(d, 32)
end

local function edScalarmult(p, q, s) -- p <- [s]q; s: 32-byte string
  set25519(p[1], gf0); set25519(p[2], gf1); set25519(p[3], gf1); set25519(p[4], gf0)
  for i = 255, 0, -1 do
    local b = math.floor(s:byte(math.floor(i / 8) + 1) / 2 ^ (i % 8)) % 2
    edCswap(p, q, b)
    edAdd(q, p)
    edAdd(p, p)
    edCswap(p, q, b)
  end
end

local function edScalarbase(p, s)
  local q = { gf(), gf(), gf(), gf() }
  set25519(q[1], BX); set25519(q[2], BY); set25519(q[3], gf1)
  M(q[4], BX, BY)
  edScalarmult(p, q, s)
end

--- Decompress a public key into the NEGATED point (yields -A, which is what
--- the verify equation wants). Returns false on a non-point.
local function edUnpackneg(r, p) -- p: 32-byte string
  local t, chk, num, den = gf(), gf(), gf(), gf()
  local den2, den4, den6 = gf(), gf(), gf()
  set25519(r[3], gf1)
  unpack25519(r[2], p)
  S(num, r[2]); M(den, num, D); Z(num, num, r[3]); A(den, r[3], den)
  S(den2, den); S(den4, den2); M(den6, den4, den2)
  M(t, den6, num); M(t, t, den)
  pow2523(t, t)
  M(t, t, num); M(t, t, den); M(t, t, den); M(r[1], t, den)
  S(chk, r[1]); M(chk, chk, den)
  if neq25519(chk, num) then M(r[1], r[1], SQRTM1) end
  S(chk, r[1]); M(chk, chk, den)
  if neq25519(chk, num) then return false end
  if par25519(r[1]) == math.floor(p:byte(32) / 128) then Z(r[1], gf0, r[1]) end
  M(r[4], r[1], r[2])
  return true
end

--- Reduce a 64-byte value mod L -> 32-byte string (TweetNaCl modL).
local function reduce(h64)
  local x = {}
  for i = 1, 64 do x[i] = h64:byte(i) end
  for i = 64, 33, -1 do
    local carry = 0
    for j = i - 32, i - 13 do
      x[j] = x[j] + carry - 16 * x[i] * LB[j - (i - 32) + 1]
      carry = math.floor((x[j] + 128) / 256)
      x[j] = x[j] - carry * 256
    end
    x[i - 12] = x[i - 12] + carry
    x[i] = 0
  end
  local carry = 0
  for j = 1, 32 do
    x[j] = x[j] + carry - math.floor(x[32] / 16) * LB[j]
    carry = math.floor(x[j] / 256)
    x[j] = x[j] % 256
  end
  for j = 1, 32 do x[j] = x[j] - carry * LB[j] end
  local out = {}
  for i = 1, 32 do
    x[i + 1] = x[i + 1] + math.floor(x[i] / 256)
    out[i] = x[i] % 256
  end
  return bytesToStr(out, 32)
end

local function sha512(data)
  return love.data.hash("sha512", data)
end

--- Ed25519 signature verification: pin (raw 32-byte public key), message,
--- 64-byte signature (R || S). Rejects non-canonical S (S >= L), matching
--- the server's OpenSSL behaviour.
function Tunnel.edVerify(pin, msg, sig)
  if #pin ~= 32 or #sig ~= 64 then return false end
  local below = false
  for i = 32, 1, -1 do
    local sb, lb = sig:byte(32 + i), LB[i]
    if sb < lb then below = true; break end
    if sb > lb then return false end
  end
  if not below then return false end -- S == L
  local q = { gf(), gf(), gf(), gf() }
  if not edUnpackneg(q, pin) then return false end
  local h = reduce(sha512(sig:sub(1, 32) .. pin .. msg))
  local p = { gf(), gf(), gf(), gf() }
  edScalarmult(p, q, h)        -- p = [h](-A)
  local qb = { gf(), gf(), gf(), gf() }
  edScalarbase(qb, sig:sub(33, 64)) -- qb = [S]B
  edAdd(p, qb)                 -- p = [S]B - [h]A; must equal R
  return edPack(p) == sig:sub(1, 32)
end

-- ------------------------------------------------ Ed25519 SIGNING
--
-- The device-key half of the passkey auth (server verifies against a stored
-- public key). TweetNaCl crypto_sign, in the same numeric model as verify
-- above: a 32-byte seed expands via SHA-512 into a clamped scalar `a` and a
-- prefix; the public key is [a]B. This is validated byte-for-byte against
-- Node's crypto in tests/love_stub / the live e2e -- a wrong port fails the
-- server's signature check, not silently.

-- Clamp the low 32 bytes of the seed hash into a valid scalar (RFC 8032).
local function clampScalar(bytes)
  bytes[1]  = bytes[1] % 256
  bytes[1]  = bytes[1] - (bytes[1] % 8)          -- clear low 3 bits
  bytes[32] = bytes[32] % 64 + 64                -- clear bit 255, set bit 254
  return bytesToStr(bytes, 32)
end

--- Derive the 32-byte Ed25519 PUBLIC key for a 32-byte seed.
function Tunnel.edPublicKey(seed)
  local h = sha512(seed)
  local a = {}
  for i = 1, 32 do a[i] = h:byte(i) end
  local scalar = clampScalar(a)
  local p = { gf(), gf(), gf(), gf() }
  edScalarbase(p, scalar)
  return edPack(p)
end

-- 64-byte scalar mul-add mod L: out = (a*b + c) mod L, TweetNaCl's inner
-- loop from crypto_sign. a,b,c are 32-byte strings (little-endian scalars).
local function mulAddModL(aStr, bStr, cStr)
  local x = {}
  for i = 1, 64 do x[i] = 0 end
  local a, b, c = {}, {}, {}
  for i = 1, 32 do a[i] = aStr:byte(i); b[i] = bStr:byte(i); c[i] = cStr:byte(i) end
  for i = 1, 32 do
    for j = 1, 32 do
      x[i + j - 1] = x[i + j - 1] + a[i] * b[j]
    end
  end
  for i = 1, 32 do x[i] = x[i] + c[i] end
  -- reduce the 64-byte value mod L (same modL TweetNaCl uses; reuse `reduce`
  -- by packing x back to a 64-byte string).
  local packed = {}
  for i = 1, 64 do packed[i] = x[i] % 256; local carry = math.floor(x[i] / 256)
    if i < 64 then x[i + 1] = x[i + 1] + carry end end
  return reduce(bytesToStr(packed, 64))
end

--- Sign `msg` with a 32-byte seed. Returns the 64-byte signature R || S.
function Tunnel.edSign(seed, msg)
  local h = sha512(seed)
  local a = {}
  for i = 1, 32 do a[i] = h:byte(i) end
  local scalar = clampScalar(a)
  local prefix = h:sub(33, 64)
  local pub = Tunnel.edPublicKey(seed)

  -- r = H(prefix || msg); R = [r]B
  local r = reduce(sha512(prefix .. msg))
  local rp = { gf(), gf(), gf(), gf() }
  edScalarbase(rp, r)
  local R = edPack(rp)

  -- S = (r + H(R || A || msg) * a) mod L
  local hram = reduce(sha512(R .. pub .. msg))
  local S = mulAddModL(hram, scalar, r)
  return R .. S
end

-- ------------------------------------------------ key schedule + session

local Crypto = SAVESYNC_INCLUDE("src/crypto.lua")

--- Must match src/crypto/identity.ts SIGN_CONTEXT on the server.
Tunnel.SIGN_CONTEXT = "g1mmo-handshake-v1:"
local HKDF_INFO = "g1mmo-tunnel-v1"

--- HKDF-SHA256(shared, salt=SHA256(cpub||spub), info, 64) -> c2s, s2c keys.
function Tunnel.deriveKeys(shared, cpubRaw, spubRaw)
  local salt = Crypto.sha256(cpubRaw .. spubRaw)
  local prk = Crypto.hmac(salt, shared)
  local t1 = Crypto.hmac(prk, HKDF_INFO .. "\1")
  local t2 = Crypto.hmac(prk, t1 .. HKDF_INFO .. "\2")
  return t1, t2
end

--- 12-byte AEAD nonce: 4 zero bytes then the frame counter as u64 LE.
--- Counters are Lua doubles: exact to 2^53 frames, unreachable in practice.
local function nonceFor(counter)
  local b = { 0, 0, 0, 0 }
  local c = counter
  for i = 5, 12 do
    b[i] = c % 256
    c = math.floor(c / 256)
  end
  return bytesToStr(b, 12)
end

local Session = {}
Session.__index = Session

--- Encrypt one outbound frame -> base64 line (no newline).
function Session:seal(plaintext)
  local sealed = Tunnel.aeadSeal(self.txKey, nonceFor(self.txCounter), plaintext)
  self.txCounter = self.txCounter + 1
  return Crypto.toBase64(sealed)
end

--- Decrypt one inbound base64 line -> plaintext, or nil (= treat as fatal).
--- The counter advances only on success, mirroring the server.
function Session:open(line)
  local ok, raw = pcall(Crypto.fromBase64, line)
  if not ok or type(raw) ~= "string" or #raw < 16 then return nil end
  local plain = Tunnel.aeadOpen(self.rxKey, nonceFor(self.rxCounter), raw)
  if plain == nil then return nil end
  self.rxCounter = self.rxCounter + 1
  return plain
end

-- ------------------------------------------------ handshake (client side)

--- Best-effort userland entropy. LOVE has no CSPRNG, so we fold together
--- every varying source in reach and hash twice with a domain tag. The stakes
--- are one ephemeral X25519 key per connection; the pinned-signature MITM
--- defence does NOT depend on this randomness.
function Tunnel.gatherEntropy(extra)
  local pool = { "g1mmo-entropy-v1:", tostring(extra) }
  if os and os.time then pool[#pool + 1] = tostring(os.time()) end
  if os and os.clock then pool[#pool + 1] = tostring(os.clock()) end
  if love.timer and love.timer.getTime then pool[#pool + 1] = tostring(love.timer.getTime()) end
  pool[#pool + 1] = tostring(collectgarbage("count"))
  pool[#pool + 1] = tostring({}) .. tostring({}) -- allocator/ASLR jitter
  if love.math and love.math.random then
    local r = {}
    for i = 1, 32 do r[i] = string.char(love.math.random(0, 255)) end
    pool[#pool + 1] = table.concat(r)
  end
  return Crypto.sha256(Crypto.sha256(table.concat(pool)))
end

--- Begin a handshake: returns { sk, cpub } with cpub the raw 32-byte
--- ephemeral public key to send (base64-encode it into the hello frame).
function Tunnel.start(rand32)
  assert(#rand32 == 32, "tunnel: need 32 bytes of entropy")
  local cpub = Tunnel.x25519Base(rand32) -- x25519 clamps internally
  return { sk = rand32, cpub = cpub }
end

--- Finish a handshake with the server's hello_ack fields (raw bytes).
--- pin is the pinned server identity (raw 32 bytes); pass nil ONLY for
--- loopback dev servers -- it skips the identity check entirely.
--- Returns a Session, or nil (= refuse the connection; likely MITM).
function Tunnel.finish(hs, spubRaw, sigRaw, pin)
  if type(spubRaw) ~= "string" or #spubRaw ~= 32 then return nil end
  if pin ~= nil then
    if type(sigRaw) ~= "string" or #sigRaw ~= 64 then return nil end
    if not Tunnel.edVerify(pin, Tunnel.SIGN_CONTEXT .. hs.cpub .. spubRaw, sigRaw) then
      return nil
    end
  end
  local shared = Tunnel.x25519(hs.sk, spubRaw)
  if shared == string.rep("\0", 32) then return nil end -- low-order garbage point
  local c2s, s2c = Tunnel.deriveKeys(shared, hs.cpub, spubRaw)
  -- Client sends c2s, receives s2c (the server holds the mirror image).
  return setmetatable({ txKey = c2s, rxKey = s2c, txCounter = 0, rxCounter = 0 }, Session)
end

return Tunnel
