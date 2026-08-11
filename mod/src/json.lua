-- Minimal JSON encode/decode.
--
-- Everything this mod puts on the wire is a small flat object of strings,
-- numbers and booleans (a sync manifest is about 200 bytes), so this covers
-- the JSON subset those need and nothing else: no NaN, no sparse-array
-- guessing, no __jsontype metatables.  Decode is tolerant of anything a
-- server might legitimately send back, including nested objects and arrays,
-- because provider APIs answer with far more than we asked for.
--
-- Empty tables encode as `{}`.  A table with a [1] encodes as an array.

local Json = {}

-- ---------------------------------------------------------------- encode

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeString(s)
  return (s:gsub('[%z\1-\31"\\]', function(c)
    return ESCAPES[c] or ("\\u%04x"):format(c:byte())
  end))
end

local encodeValue

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("json: cannot encode " .. tostring(n))
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return ("%d"):format(n)
  end
  return ("%.14g"):format(n)
end

-- An empty table encodes as `{}`, not `[]`.  Every empty collection this mod
-- sends is an object (a manifest, a gist `files` map), and a stray `[]` is
-- the difference between an accepted and a rejected API call.
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

encodeValue = function(v, out)
  local ty = type(v)
  if v == nil then
    out[#out + 1] = "null"
  elseif ty == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif ty == "number" then
    out[#out + 1] = encodeNumber(v)
  elseif ty == "string" then
    out[#out + 1] = '"' .. escapeString(v) .. '"'
  elseif ty == "table" then
    if isArray(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], out)
      end
      out[#out + 1] = "]"
    else
      -- sorted keys: a manifest that round-trips byte-identically is far
      -- easier to diff by hand in the provider's own web UI
      local keys = {}
      for k in pairs(v) do
        if type(k) == "string" then keys[#keys + 1] = k end
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = '"' .. escapeString(k) .. '":'
        encodeValue(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: cannot encode " .. ty)
  end
end

function Json.encode(v)
  local out = {}
  encodeValue(v, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------- decode

local function skipWs(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or i - 1) + 1
end

local parseValue

local function parseString(s, i)
  -- i points at the opening quote
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("json: unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local hex = s:sub(j + 2, j + 5)
        local code = tonumber(hex, 16) or 63
        -- UTF-8 encode; surrogate pairs collapse to the replacement char,
        -- which is fine for the ASCII-ish payloads this handles
        if code < 0x80 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 64),
            0x80 + code % 64)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 4096),
            0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
        end
        j = j + 6
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        out[#out + 1] = map[e] or e
        j = j + 2
      end
    else
      local nextEsc = s:find('["\\]', j)
      out[#out + 1] = s:sub(j, (nextEsc or #s + 1) - 1)
      j = nextEsc or #s + 1
    end
  end
end

parseValue = function(s, i)
  i = skipWs(s, i)
  local c = s:sub(i, i)
  if c == "" then error("json: unexpected end of input") end
  if c == '"' then return parseString(s, i) end
  if c == "{" then
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local key
      i = skipWs(s, i)
      key, i = parseString(s, i)
      i = skipWs(s, i)
      if s:sub(i, i) ~= ":" then error("json: expected ':'") end
      local val
      val, i = parseValue(s, i + 1)
      obj[key] = val
      i = skipWs(s, i)
      local sep = s:sub(i, i)
      if sep == "," then i = i + 1
      elseif sep == "}" then return obj, i + 1
      else error("json: expected ',' or '}'") end
    end
  end
  if c == "[" then
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local val
      val, i = parseValue(s, i)
      arr[#arr + 1] = val
      i = skipWs(s, i)
      local sep = s:sub(i, i)
      if sep == "," then i = i + 1
      elseif sep == "]" then return arr, i + 1
      else error("json: expected ',' or ']'") end
    end
  end
  if s:sub(i, i + 3) == "true" then return true, i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null" then return nil, i + 4 end
  local num, j = s:match("^(-?%d+%.?%d*[eE]?[-+]?%d*)()", i)
  if num then return tonumber(num), j end
  error("json: unexpected character '" .. c .. "'")
end

--- Decode; returns nil + message rather than throwing, because every caller
--- is parsing a remote response and has to survive garbage.
function Json.decode(s)
  if type(s) ~= "string" or s == "" then return nil, "empty" end
  local ok, val = pcall(function()
    local v = parseValue(s, 1)
    return v
  end)
  if not ok then return nil, tostring(val) end
  return val
end

return Json
