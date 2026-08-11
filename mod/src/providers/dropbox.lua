-- Dropbox provider: the app's own folder inside the player's Dropbox.
--
-- Dropbox is the "common account" option -- far more people have one than
-- have a GitHub account -- and the App Folder permission means the mod can
-- only ever see `Apps/<app name>/`, never the rest of their files.
--
-- There is no device flow here, so the link is PKCE with no redirect URI:
-- Dropbox shows the player a code on its own page and they paste it back.
-- The UI drives that with the clipboard (copy in the browser, press A in the
-- game), so nobody has to type 43 characters on a d-pad.
--
-- Access tokens last four hours; `token_access_type=offline` gets a refresh
-- token alongside, and a 401 refreshes and retries exactly once.

local Op = SAVESYNC_INCLUDE("src/op.lua")
local Json = SAVESYNC_INCLUDE("src/json.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")

local P = {}

P.id = "dropbox"
P.label = "Dropbox"
P.blurb = "Uses one folder in your Dropbox. Nothing else is visible."
P.linkStyle = "browser"         -- open a page, paste the code back
P.needsClientId = true

local UA = "gen1recomp-savesync"
local TOKEN_URL = "https://api.dropboxapi.com/oauth2/token"
local RPC = "https://api.dropboxapi.com/2"
local CONTENT = "https://content.dropboxapi.com/2"

-- ------------------------------------------------------------------ PKCE

local function pkcePair()
  local verifier = Util.b64url(Util.randomId(32))
  local challenge
  if love and love.data and love.data.hash then
    local ok, raw = pcall(love.data.hash, "sha256", verifier)
    if ok and raw then challenge = Util.b64url(raw) end
  end
  -- No SHA-256 on this host: Dropbox still accepts the "plain" method, which
  -- is weaker but keeps the provider usable rather than absent.  The method
  -- travels with the challenge so the token call stays consistent.
  if not challenge then return verifier, verifier, "plain" end
  return verifier, challenge, "S256"
end

--- Build the page the player signs in on.
---
--- NO `scope` PARAMETER, deliberately.  The scopes ticked on the app's
--- Permissions tab are both the default AND the maximum Dropbox will grant,
--- so omitting the parameter asks for exactly what the app was configured
--- with -- and can therefore never over-request and fail.  Naming the three
--- scopes here instead would only add a way for the sign-in to break if the
--- app's configuration and this list ever drift apart.  A permission that is
--- genuinely missing surfaces at the first sync, where `missingScope` names
--- it exactly.
function P.authUrl(clientId, challenge, method)
  return "https://www.dropbox.com/oauth2/authorize?"
    .. Util.form({
      client_id = clientId,
      response_type = "code",
      token_access_type = "offline",
      code_challenge = challenge,
      code_challenge_method = method,
    })
end

-- ------------------------------------------------------------------ link

--- Two-stage: the op sets `state.authUrl` and then waits for the UI to put
--- the pasted code in `state.pasted`.  Waiting inside the op keeps the whole
--- exchange in one place instead of splitting it across UI callbacks.
function P.link(state, opts)
  local clientId = opts and opts.clientId
  return Op.new(function(ctx)
    if not clientId or clientId == "" then
      return ctx:fail("no Dropbox app key is configured (see docs/providers.md)")
    end
    local verifier, challenge, method = pkcePair()
    state.authUrl = P.authUrl(clientId, challenge, method)
    state.message = "Sign in, then copy the code Dropbox shows you"
    state.awaitPaste = true

    local deadline = os.time() + 900
    while not state.pasted do
      if state.cancelled then return ctx:fail("cancelled") end
      if os.time() > deadline then return ctx:fail("timed out -- try Set Up again") end
      ctx:sleep(0.5)
    end
    -- A player who pastes a whole URL, or a code with spaces around it, is
    -- doing the obviously-right thing; take the code out rather than fail.
    local code = tostring(state.pasted):gsub("%s", ""):match("[^=/?&]+$") or ""
    state.awaitPaste = false
    state.message = "Checking that code..."

    local res = ctx:http({
      method = "POST", url = TOKEN_URL,
      headers = { ["Content-Type"] = "application/x-www-form-urlencoded",
                  ["User-Agent"] = UA },
      body = Util.form({
        code = code,
        grant_type = "authorization_code",
        client_id = clientId,
        code_verifier = verifier,
      }),
    })
    if not res.ok then return ctx:fail(res.err or "could not reach Dropbox") end
    local t = Json.decode(res.body or "") or {}
    if res.code ~= 200 or not t.access_token then
      return ctx:fail("Dropbox did not accept that code -- try Set Up again")
    end
    return {
      provider = "dropbox",
      clientId = clientId,
      access = t.access_token,
      refresh = t.refresh_token,
      expires = os.time() + (tonumber(t.expires_in) or 14000) - 60,
      account = "Dropbox",
    }
  end)
end

function P.describe(cfg)
  return "Dropbox"
end

function P.exportable(cfg)
  -- The refresh token is the durable credential; a paired device mints its
  -- own access tokens from it and never needs the short-lived one.
  return { provider = "dropbox", clientId = cfg.clientId,
           refresh = cfg.refresh, account = cfg.account }
end

--- Rebuild a live config from a pairing code (no browser round trip).
function P.adopt(state)
  return Op.new(function(ctx)
    local p = state.pasted
    if type(p) ~= "table" or p.provider ~= "dropbox" or not p.refresh then
      return ctx:fail("that setup code is not a Dropbox one")
    end
    return { provider = "dropbox", clientId = p.clientId, refresh = p.refresh,
             access = nil, expires = 0, account = p.account or "Dropbox" }
  end)
end

-- --------------------------------------------------------------- storage

-- Mint a fresh access token from the refresh token.  Sets cfg.dirty so the
-- sync engine writes the new one to disk; without that every launch would
-- spend a round trip re-refreshing.
local function refresh(ctx, cfg)
  if not (cfg.refresh and cfg.clientId) then
    return false, "Dropbox sign-in expired -- set up SaveSync again"
  end
  local res = ctx:http({
    method = "POST", url = TOKEN_URL,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded",
                ["User-Agent"] = UA },
    body = Util.form({
      grant_type = "refresh_token",
      refresh_token = cfg.refresh,
      client_id = cfg.clientId,
    }),
  })
  if not res.ok then return false, res.err or "could not reach Dropbox" end
  local t = Json.decode(res.body or "") or {}
  if res.code ~= 200 or not t.access_token then
    return false, "Dropbox sign-in expired -- set up SaveSync again"
  end
  cfg.access = t.access_token
  cfg.expires = os.time() + (tonumber(t.expires_in) or 14000) - 60
  cfg.dirty = true
  return true
end

-- Dropbox answers a permission the app was never granted with a 401 whose
-- body is `missing_scope`, which looks exactly like an expired token and is
-- not one.  Refreshing cannot fix it -- the token is fine, the APP is missing
-- a permission -- so it has to be told apart, or the only symptom is a
-- refresh loop reporting "sign-in expired" at someone whose sign-in is
-- perfectly good.  The required scope is in the body; put it in the message,
-- because the fix is to tick that box in the App Console.
local function missingScope(res)
  if not (res and res.code == 401 and type(res.body) == "string") then return nil end
  if not res.body:find("missing_scope", 1, true) then return nil end
  local want = res.body:match('"required_scope"%s*:%s*"([^"]+)"')
  return "your Dropbox app is missing the "
    .. (want or "required")
    .. " permission -- add it, then set up SaveSync again"
end

-- One authenticated call, refreshing once on expiry or a 401.
local function call(ctx, cfg, req)
  if not cfg.access or (cfg.expires or 0) <= os.time() then
    local ok, err = refresh(ctx, cfg)
    if not ok then return nil, err end
  end
  req.headers = req.headers or {}
  req.headers["Authorization"] = "Bearer " .. cfg.access
  req.headers["User-Agent"] = UA
  local res = ctx:http(req)
  if res.ok and res.code == 401 then
    local scopeErr = missingScope(res)
    if scopeErr then return nil, scopeErr end
    local ok, err = refresh(ctx, cfg)
    if not ok then return nil, err end
    req.headers["Authorization"] = "Bearer " .. cfg.access
    res = ctx:http(req)
    scopeErr = missingScope(res)
    if scopeErr then return nil, scopeErr end
  end
  if not res.ok then return nil, res.err or "no connection" end
  return res
end

-- Dropbox takes its file arguments in a HEADER, which must be plain ASCII.
local function apiArg(t)
  return (Json.encode(t):gsub("[\128-\255]", function(c)
    return ("\\u%04x"):format(c:byte())
  end))
end

function P.read(cfg, names)
  return Op.new(function(ctx)
    local out = {}
    for _, name in ipairs(names or {}) do
      local res, err = call(ctx, cfg, {
        method = "POST",
        url = CONTENT .. "/files/download",
        headers = { ["Dropbox-API-Arg"] = apiArg({ path = "/" .. name }) },
      })
      if not res then return ctx:fail(err) end
      if res.code == 200 then
        out[name] = res.body
      elseif res.code ~= 409 then
        -- 409 is Dropbox's "path/not_found", the normal answer for a save
        -- this device has not uploaded yet
        return ctx:fail("Dropbox said HTTP " .. tostring(res.code))
      end
    end
    return out
  end)
end

function P.write(cfg, files)
  return Op.new(function(ctx)
    local deletes = {}
    for name, content in pairs(files) do
      if content == false then
        deletes[#deletes + 1] = name
      else
        local res, err = call(ctx, cfg, {
          method = "POST",
          url = CONTENT .. "/files/upload",
          headers = {
            ["Dropbox-API-Arg"] = apiArg({ path = "/" .. name, mode = "overwrite",
                                           mute = true }),
            ["Content-Type"] = "application/octet-stream",
          },
          body = content,
        })
        if not res then return ctx:fail(err) end
        if res.code ~= 200 then
          return ctx:fail("Dropbox said HTTP " .. tostring(res.code)
            .. " uploading " .. name)
        end
      end
    end
    for _, name in ipairs(deletes) do
      -- A delete that finds nothing is success as far as sync is concerned:
      -- pruning old history must never be able to fail a sync.
      call(ctx, cfg, {
        method = "POST",
        url = RPC .. "/files/delete_v2",
        headers = { ["Content-Type"] = "application/json" },
        body = Json.encode({ path = "/" .. name }),
      })
    end
    return true
  end)
end

function P.list(cfg)
  return Op.new(function(ctx)
    local out = {}
    local res, err = call(ctx, cfg, {
      method = "POST",
      url = RPC .. "/files/list_folder",
      headers = { ["Content-Type"] = "application/json" },
      body = Json.encode({ path = "" }),
    })
    if not res then return ctx:fail(err) end
    if res.code ~= 200 then
      return ctx:fail("Dropbox said HTTP " .. tostring(res.code))
    end
    local page = Json.decode(res.body or "") or {}
    for _, e in ipairs(page.entries or {}) do
      if e[".tag"] == "file" then out[e.name] = e.size or 0 end
    end
    -- A player's folder holds a handful of files, so one page is the whole
    -- story; continue anyway rather than silently truncate a long history.
    while page.has_more do
      local more, merr = call(ctx, cfg, {
        method = "POST",
        url = RPC .. "/files/list_folder/continue",
        headers = { ["Content-Type"] = "application/json" },
        body = Json.encode({ cursor = page.cursor }),
      })
      if not more or more.code ~= 200 then break end
      page = Json.decode(more.body or "") or {}
      for _, e in ipairs(page.entries or {}) do
        if e[".tag"] == "file" then out[e.name] = e.size or 0 end
      end
    end
    return out
  end)
end

return P
