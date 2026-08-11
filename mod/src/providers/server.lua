-- Self-hosted provider: the player's own tiny server (see server/ in this
-- repository), reached with a setup code.
--
-- This is the fallback that guarantees the mod outlives any one company.
-- The protocol is deliberately four endpoints of plain HTTP so that writing a
-- replacement backend is an afternoon, not a project:
--
--   GET  {base}/v1/hello           -> { ok = true, name = "..." }
--   GET  {base}/v1/files           -> { files = { ["name"] = size, ... } }
--   GET  {base}/v1/file/{name}     -> the raw bytes, or 404
--   POST {base}/v1/batch           -> { files = { name = "content" | null } }
--
-- Every request carries `Authorization: Bearer <token>`.  The token names the
-- storage: two devices holding the same token see the same saves, which is
-- all "pair another device" has ever needed to mean.

local Op = CLOUD_SAVES_INCLUDE("src/op.lua")
local Json = CLOUD_SAVES_INCLUDE("src/json.lua")

local P = {}

P.id = "server"
P.label = "My own server"
P.blurb = "For advanced users running the Docker backend."
P.linkStyle = "paste"           -- the UI asks for a setup code
P.needsClientId = false

local UA = "gen1recomp-cloudsaves"

local function headers(cfg, extra)
  local h = {
    ["Authorization"] = "Bearer " .. tostring(cfg.token or ""),
    ["User-Agent"] = UA,
  }
  for k, v in pairs(extra or {}) do h[k] = v end
  return h
end

local function base(cfg)
  return (tostring(cfg.url or ""):gsub("/+$", ""))
end

-- ------------------------------------------------------------------ link

--- `state.pasted` carries the decoded pairing payload the UI collected.
--- Linking is one round trip that proves the URL and token actually work,
--- so a typo fails at Set Up rather than silently at the first sync.
function P.link(state, _opts)
  return Op.new(function(ctx)
    local pasted = state.pasted
    if type(pasted) ~= "table" or not pasted.url or not pasted.token then
      return ctx:fail("that setup code is not for a self-hosted server")
    end
    local cfg = { provider = "server", url = pasted.url, token = pasted.token }
    state.message = "Checking your server..."
    local res = ctx:http({ url = base(cfg) .. "/v1/hello", headers = headers(cfg) })
    if not res.ok then return ctx:fail(res.err or "could not reach that server") end
    if res.code == 401 then return ctx:fail("that server rejected the code") end
    if res.code ~= 200 then
      return ctx:fail("that server said HTTP " .. tostring(res.code))
    end
    local hello = Json.decode(res.body or "") or {}
    cfg.account = hello.name or pasted.url
    return cfg
  end)
end

function P.describe(cfg)
  return "Server: " .. tostring(cfg and (cfg.account or cfg.url) or "?")
end

function P.exportable(cfg)
  return { provider = "server", url = cfg.url, token = cfg.token,
           account = cfg.account }
end

-- --------------------------------------------------------------- storage

function P.read(cfg, names)
  return Op.new(function(ctx)
    local out = {}
    for _, name in ipairs(names or {}) do
      local res = ctx:http({
        url = base(cfg) .. "/v1/file/" .. name,
        headers = headers(cfg),
      })
      if not res.ok then return ctx:fail(res.err or "no connection") end
      if res.code == 200 then
        out[name] = res.body
      elseif res.code == 401 then
        return ctx:fail("your server rejected the saved code")
      elseif res.code ~= 404 then
        return ctx:fail("your server said HTTP " .. tostring(res.code))
      end
    end
    return out
  end)
end

function P.write(cfg, files)
  return Op.new(function(ctx)
    -- Deletions are JSON null, which Json.encode cannot express; build the
    -- object text directly rather than teach the encoder a null sentinel.
    local parts = {}
    for name, content in pairs(files) do
      local key = Json.encode(name)
      parts[#parts + 1] = key .. ":"
        .. (content == false and "null" or Json.encode(content))
    end
    if #parts == 0 then return true end
    table.sort(parts)
    local body = '{"files":{' .. table.concat(parts, ",") .. "}}"

    local res = ctx:http({
      method = "POST",
      url = base(cfg) .. "/v1/batch",
      headers = headers(cfg, { ["Content-Type"] = "application/json" }),
      body = body,
    })
    if not res.ok then return ctx:fail(res.err or "no connection") end
    if res.code == 401 then return ctx:fail("your server rejected the saved code") end
    if res.code ~= 200 then
      return ctx:fail("your server said HTTP " .. tostring(res.code))
    end
    return true
  end)
end

function P.list(cfg)
  return Op.new(function(ctx)
    local res = ctx:http({ url = base(cfg) .. "/v1/files", headers = headers(cfg) })
    if not res.ok then return ctx:fail(res.err or "no connection") end
    if res.code ~= 200 then
      return ctx:fail("your server said HTTP " .. tostring(res.code))
    end
    return (Json.decode(res.body or "") or {}).files or {}
  end)
end

return P
