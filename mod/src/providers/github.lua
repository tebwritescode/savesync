-- GitHub provider: one secret gist per player, reached by the OAuth device
-- flow.
--
-- WHY A GIST AND NOT A REPO.  A gist needs the `gist` scope, which grants
-- access to gists and nothing else.  The `repo` scope a private repository
-- would need grants read/write over every private repository the player
-- owns -- an absurd thing to ask for in exchange for storing a 30 KB save
-- file, and the sort of consent screen that (rightly) makes people back out.
-- A secret gist is free, unlimited for this size, versioned by git, and
-- invisible in the user's public profile.
--
-- WHY THE DEVICE FLOW.  It is the only OAuth flow that needs no redirect URI
-- and no client secret, which means no server anywhere in the loop: the game
-- shows an eight-character code, the player types it at github.com/login/
-- device on any device they like, and the game gets a token.  Signing in
-- again on a second machine finds the SAME gist by its description marker,
-- so "pair another device" is just "sign in again" -- no code to copy at all.

local Op = SAVESYNC_INCLUDE("src/op.lua")
local Json = SAVESYNC_INCLUDE("src/json.lua")
local Util = SAVESYNC_INCLUDE("src/util.lua")

local P = {}

P.id = "github"
P.label = "GitHub"
-- HTTPS ONLY. A device whose only transport is luasocket (LOVE bundles it;
-- luasec, which would add TLS, it does not) cannot reach this service at all,
-- so Set Up hides it there rather than offering a sign-in that cannot finish.
P.needsTls = true
P.blurb = "Free, no limits at this size. Recommended."
P.linkStyle = "device"          -- the UI shows a code and a URL
P.needsClientId = true

-- Every gist this mod owns carries this exact description.  It is how a
-- second device finds the storage the first one created, and how the mod
-- avoids ever touching a gist the player made themselves.
local MARKER = "gen1recomp SaveSync (do not rename)"

local API = "https://api.github.com"
local WEB = "https://github.com"
local UA = "gen1recomp-savesync"

-- TEST SEAM.  GitHub has no sandbox a mod can point at, and the one bug that
-- has actually reached a player here (a gist created with only the
-- link-time README, no save ever arriving) was invisible precisely because
-- nothing exercised this file against a real server.  `cfg.apiBase` /
-- `cfg.webBase` let a test substitute a fake one; a real cfg never has these
-- fields, `apiBase()`/`webBase()` fall back to the real endpoints, and
-- nothing a player does can set them, so this changes nothing for anyone
-- signed in for real.
local function apiBase(cfg) return (cfg and cfg.apiBase) or API end
local function webBase(cfg) return (cfg and cfg.webBase) or WEB end

-- Content-Type MUST be explicit.  curl defaults an unlabelled body to
-- application/x-www-form-urlencoded, and every call below sends
-- Json.encode()'d text -- so leaving this out means GitHub receives JSON
-- wearing a form-data label on every gist create/update.  That mismatch was
-- caught by the harness in tests/github.test.js, which is also the only
-- place able to catch it: it needs a real Content-Type header to inspect,
-- which nothing short of an actual HTTP request produces.
local function apiHeaders(token)
  return {
    ["Authorization"] = "Bearer " .. token,
    ["Accept"] = "application/vnd.github+json",
    ["Content-Type"] = "application/json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
    ["User-Agent"] = UA,
  }
end

-- Gist filenames cannot contain "/".  The store already uses flat names for
-- exactly this reason, so this is only a guard against a future caller.
local function safeName(name)
  return (tostring(name):gsub("/", "~"))
end

-- ------------------------------------------------------------------ link

--- Run the device flow and end up with a usable config.
--- `state` is a table the UI reads while this runs: userCode, verifyUrl and
--- message are written into it as they become known.
function P.link(state, opts)
  local clientId = opts and opts.clientId
  -- Read once up front: opts is only around for this call, but the chosen
  -- base has to keep working for every P.read/write/list this cfg ever
  -- makes, so it travels onward inside the returned cfg instead.
  local web = webBase(opts)
  local api = apiBase(opts)
  return Op.new(function(ctx)
    if not clientId or clientId == "" then
      return ctx:fail("no GitHub client id is configured (see docs/providers.md)")
    end

    state.message = "Asking GitHub for a code..."
    local res = ctx:http({
      method = "POST",
      url = web .. "/login/device/code",
      headers = { ["Accept"] = "application/json", ["User-Agent"] = UA },
      body = Util.form({ client_id = clientId, scope = "gist" }),
    })
    if not res.ok then return ctx:fail(res.err or "could not reach GitHub") end
    local d = Json.decode(res.body or "")
    if type(d) ~= "table" or not d.device_code then
      return ctx:fail("GitHub refused the sign-in request")
    end

    state.userCode = d.user_code
    state.verifyUrl = d.verification_uri or "https://github.com/login/device"
    state.message = "Enter this code at " .. state.verifyUrl

    -- GitHub sets the minimum poll interval and answers slow_down when we
    -- ignore it; honour both, and give up when the code expires rather than
    -- polling a dead device_code forever.
    local interval = tonumber(d.interval) or 5
    local deadline = os.time() + (tonumber(d.expires_in) or 900)
    local token
    while os.time() < deadline do
      ctx:sleep(interval)
      local tr = ctx:http({
        method = "POST",
        url = web .. "/login/oauth/access_token",
        headers = { ["Accept"] = "application/json", ["User-Agent"] = UA },
        body = Util.form({
          client_id = clientId,
          device_code = d.device_code,
          grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        }),
      })
      if tr.ok then
        local t = Json.decode(tr.body or "") or {}
        if t.access_token then
          token = t.access_token
          break
        elseif t.error == "slow_down" then
          interval = interval + 5
        elseif t.error == "access_denied" then
          return ctx:fail("sign-in was cancelled on GitHub")
        elseif t.error == "expired_token" then
          return ctx:fail("the code expired -- start Set Up again")
        end
        -- authorization_pending: keep waiting, that is the normal case
      end
    end
    if not token then return ctx:fail("the code expired -- start Set Up again") end

    state.userCode = nil
    state.message = "Signed in. Finding your save storage..."

    local who = ctx:http({ url = api .. "/user", headers = apiHeaders(token) })
    if not who.ok or who.code ~= 200 then
      return ctx:fail("signed in, but GitHub would not say who you are")
    end
    local login = (Json.decode(who.body or "") or {}).login or "?"

    -- Reuse the gist a previous device made.  This is what makes pairing a
    -- second device a plain sign-in: same account, same storage, no code.
    local gistId
    local page = 1
    while page <= 5 and not gistId do
      local ls = ctx:http({
        url = api .. "/gists?per_page=100&page=" .. page,
        headers = apiHeaders(token),
      })
      if not ls.ok or ls.code ~= 200 then break end
      local arr = Json.decode(ls.body or "") or {}
      if #arr == 0 then break end
      for _, g in ipairs(arr) do
        if g.description == MARKER then gistId = g.id break end
      end
      page = page + 1
    end

    if not gistId then
      state.message = "Creating your save storage..."
      local body = Json.encode({
        description = MARKER,
        public = false,
        files = {
          ["README.md"] = { content =
            "Gen1Recomp cloud saves live here.\n\n"
            .. "Each `.sav` file is one save slot; the matching `.json` is its\n"
            .. "sync manifest and the `.h*.sav` files are previous versions.\n"
            .. "This gist is secret. Deleting it deletes your cloud saves.\n" },
        },
      })
      local cr = ctx:http({
        method = "POST", url = api .. "/gists",
        headers = apiHeaders(token), body = body,
      })
      if not cr.ok or (cr.code ~= 201 and cr.code ~= 200) then
        return ctx:fail("could not create the storage gist (HTTP "
          .. tostring(cr.code) .. ")")
      end
      gistId = (Json.decode(cr.body or "") or {}).id
      if not gistId then return ctx:fail("GitHub did not return a gist id") end
    end

    return {
      provider = "github",
      token = token,
      gist = gistId,
      account = login,
      -- nil on a real sign-in (api/web already equal the real constants), so
      -- this adds nothing to a player's saved config.
      apiBase = api ~= API and api or nil,
      webBase = web ~= WEB and web or nil,
    }
  end)
end

function P.describe(cfg)
  return "GitHub: " .. tostring(cfg and cfg.account or "?")
end

--- What a pairing code carries.  Signing in again is the better path on
--- GitHub, but a code still works and is the only option on a device with no
--- browser at all.
function P.exportable(cfg)
  return { provider = "github", token = cfg.token, gist = cfg.gist,
           account = cfg.account, apiBase = cfg.apiBase, webBase = cfg.webBase }
end

--- Rebuild a live config from a pairing code.
---
--- WITHOUT THIS, PAIRING RAN THE SIGN-IN FLOW. The screen picks
--- `provider.adopt or provider.link`, and GitHub had no adopt -- so pasting a
--- GitHub setup code started the interactive device flow instead, handed it
--- `payload.clientId`, which a GitHub code has never carried, and stopped on
--- "no GitHub client id is configured". A pasted code already holds a working
--- token; it needs no client id, no browser and no sign-in at all.
---
--- The token is CHECKED rather than trusted, so pairing can say plainly
--- whether it worked instead of failing later during a sync.
function P.adopt(state)
  return Op.new(function(ctx)
    local p = state.pasted
    if type(p) ~= "table" or p.provider ~= "github" then
      return ctx:fail("that setup code is not a GitHub one")
    end
    if not p.token or p.token == "" then
      return ctx:fail("that setup code carries no GitHub sign-in")
    end
    if not p.gist or p.gist == "" then
      return ctx:fail("that setup code names no storage")
    end
    local cfg = { provider = "github", token = p.token, gist = p.gist,
                  account = p.account, apiBase = p.apiBase, webBase = p.webBase }

    state.message = "Checking the code..."
    local res = ctx:http({
      url = apiBase(cfg) .. "/gists/" .. cfg.gist,
      headers = apiHeaders(cfg.token),
    })
    if not res.ok then return ctx:fail(res.err or "could not reach GitHub") end
    if res.code == 401 then
      return ctx:fail("that setup code has expired -- make a new one")
    end
    if res.code == 404 then
      return ctx:fail("the saves that code points at are gone")
    end
    if res.code ~= 200 then
      return ctx:fail("GitHub said HTTP " .. tostring(res.code))
    end
    local d = Json.decode(res.body or "") or {}
    cfg.account = cfg.account
      or (type(d.owner) == "table" and d.owner.login) or "GitHub"
    return cfg
  end)
end

-- --------------------------------------------------------------- storage

local function fetchGist(ctx, cfg)
  local res = ctx:http({
    url = apiBase(cfg) .. "/gists/" .. cfg.gist,
    headers = apiHeaders(cfg.token),
  })
  if not res.ok then return nil, res.err or "no connection" end
  if res.code == 404 then
    return nil, "the storage gist is gone -- set up SaveSync again"
  end
  if res.code == 401 then
    return nil, "GitHub sign-in expired -- set up SaveSync again"
  end
  if res.code ~= 200 then
    return nil, "GitHub said HTTP " .. tostring(res.code)
  end
  local g = Json.decode(res.body or "")
  if type(g) ~= "table" or type(g.files) ~= "table" then
    return nil, "GitHub sent something unreadable"
  end
  return g
end

--- Read named files.  One request returns the whole gist, so `names` is
--- advisory: everything present comes back and the caller picks.
function P.read(cfg, names)
  return Op.new(function(ctx)
    local g, err = fetchGist(ctx, cfg)
    if not g then return ctx:fail(err) end
    local out = {}
    for fname, f in pairs(g.files) do
      if f.truncated then
        -- Only possible above 1 MB, which a Gen 1 save is nowhere near; if
        -- it ever happens, fetch the real bytes rather than store a stub.
        local raw = ctx:http({ url = f.raw_url, headers = apiHeaders(cfg.token) })
        out[fname] = raw.ok and raw.code == 200 and raw.body or nil
      else
        out[fname] = f.content
      end
    end
    -- honour the request list when one was given, so callers cannot come to
    -- depend on the whole-gist read that only this provider can offer
    if names and #names > 0 then
      local picked = {}
      for _, n in ipairs(names) do picked[n] = out[safeName(n)] end
      return picked
    end
    return out
  end)
end

--- Write and delete in one PATCH: `files` maps name -> content, or name ->
--- false to delete.  One request per sync is the whole point -- it keeps the
--- rate-limit budget irrelevant and makes an interrupted sync leave either
--- the old state or the new one.
function P.write(cfg, files)
  return Op.new(function(ctx)
    local payload = {}
    local any = false
    for name, content in pairs(files) do
      any = true
      if content == false then
        payload[safeName(name)] = nil        -- filled in below as JSON null
      else
        payload[safeName(name)] = { content = content }
      end
    end
    if not any then return true end

    -- Json.encode has no null, and a deleted file must serialise as
    -- `"name": null`, so the deletions are spliced into the encoded text.
    local body = Json.encode({ files = payload })
    local deletions = {}
    for name, content in pairs(files) do
      if content == false then
        deletions[#deletions + 1] = '"' .. safeName(name) .. '":null'
      end
    end
    if #deletions > 0 then
      local inner = body:match('^{"files":{(.*)}}$')
      if not inner then return ctx:fail("could not build the update") end
      local joined = table.concat(deletions, ",")
      body = '{"files":{' .. (inner ~= "" and (inner .. ",") or "") .. joined .. "}}"
    end

    local res = ctx:http({
      method = "PATCH",
      url = apiBase(cfg) .. "/gists/" .. cfg.gist,
      headers = apiHeaders(cfg.token),
      body = body,
    })
    if not res.ok then return ctx:fail(res.err or "no connection") end
    if res.code == 401 then
      return ctx:fail("GitHub sign-in expired -- set up SaveSync again")
    end
    if res.code ~= 200 then
      return ctx:fail("GitHub said HTTP " .. tostring(res.code))
    end
    return true
  end)
end

function P.list(cfg)
  return Op.new(function(ctx)
    local g, err = fetchGist(ctx, cfg)
    if not g then return ctx:fail(err) end
    local out = {}
    for fname, f in pairs(g.files) do out[fname] = f.size or 0 end
    return out
  end)
end

return P
